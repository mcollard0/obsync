#!/bin/bash

# ==============================================================================
# obsync (Final Version)
# ------------------------------------------------------------------------------
# A robust wrapper for Obsidian on Linux.
# Features:
# 1. Zero-CPU "Block-Until-Silence" watcher (No polling, no sleep loops)
# 2. Proper signal trapping (No zombie processes on kill)
# 3. Native Git concurrency safety
# ==============================================================================

set -u # Exit on undefined variables

# --- CONFIGURATION ---
readonly OBSIDIAN_CONFIG="${HOME}/.config/obsidian/obsidian.json";
readonly DEBOUNCE_SECONDS=60;
readonly SCRIPT_NAME="obsync";
readonly EXCLUDE_PATTERN='(\.git/|\.obsidian/workspace)';

# --- GLOBAL STATE ---
declare -a VAULTS=();
OBSIDIAN_PID="";
WATCHER_BG_PID="";

# --- LOGGING ---
readonly GREEN='\033[0;32m';
readonly YELLOW='\033[1;33m';
readonly RED='\033[0;31m';
readonly NC='\033[0m';

log_info() { echo -e "${GREEN}[${SCRIPT_NAME}]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[${SCRIPT_NAME}]${NC} $*"; }
log_error() { echo -e "${RED}[${SCRIPT_NAME}]${NC} $*" >&2; }

# --- CORE FUNCTIONS ---

install_desktop_entry() {
    log_info "Installing desktop entry...";
    local script_path;
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"; # Get absolute path to this script
    
    local system_desktop="/usr/share/applications/obsidian.desktop"; # Check system desktop entry
    if [[ ! -f "$system_desktop" ]]; then
        log_error "System Obsidian desktop entry not found at $system_desktop";
        log_error "Please install Obsidian first.";
        exit 1;
    fi;
    
    mkdir -p "${HOME}/.local/share/applications"; # Create local applications directory if missing
    local local_desktop="${HOME}/.local/share/applications/obsidian.desktop";
    cp "$system_desktop" "$local_desktop"; # Copy system desktop entry
    sed -i "s|^Exec=.*|Exec=$script_path %U|" "$local_desktop"; # Update Exec line to point to this script
    
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true; # Update desktop database
    fi;
    
    log_info "Desktop entry installed successfully!";
    log_info "Your DE will now launch $script_path when you click the Obsidian launcher.";
    log_info "The local desktop entry in ~/.local/share/applications/ overrides the system one.";
}

check_prerequisites() {
    local missing=();
    for cmd in inotifywait jq obsidian git notify-send; do
        if ! command -v "$cmd" &> /dev/null; then missing+=("$cmd"); fi;
    done;
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}. Install: sudo apt install inotify-tools jq git libnotify-bin";
        exit 1;
    fi;
    
    if [[ ! -f "$OBSIDIAN_CONFIG" ]]; then
        log_error "Config not found: $OBSIDIAN_CONFIG";
        exit 1;
    fi;
}

discover_vaults() {
    log_info "Discovering vaults...";
    local paths;
    paths=$(jq -r '.vaults // {} | to_entries[] | .value.path // .value' "$OBSIDIAN_CONFIG" 2>/dev/null); # Robust jq parsing for simple paths and vault objects
    
    while IFS= read -r path; do
        if [[ -n "$path" && -d "$path" ]]; then
            VAULTS+=("$path");
        fi;
    done <<< "$paths"

    if [[ ${#VAULTS[@]} -eq 0 ]]; then
        log_error "No vaults found.";
        exit 1;
    fi;
    log_info "Found ${#VAULTS[@]} vault(s).";
}

git_sync() {
    local vault_path="$1";
    local msg="$2";
    
    if [[ ! -d "$vault_path/.git" ]]; then return; fi;
    
    (
        cd "$vault_path" || exit; # Run in subshell to preserve current directory
        local has_changes=0;
        if [[ -n $(git status --porcelain) ]]; then
            log_info "Syncing $(basename "$vault_path")...";
            git add .;
            git commit -m "$msg" --quiet && has_changes=1;
        fi;
        
        if git remote | grep -q .; then # Push if local commit was created OR if unpushed commits exist
            if [[ $has_changes -eq 1 ]] || [[ -n $(git cherry 2>/dev/null) ]]; then
                git push --quiet || log_warn "Push failed (Offline?)";
            fi;
        fi;
    )
}

preflight_sync() {
    for vault in "${VAULTS[@]}"; do
        if [[ -d "$vault/.git" ]]; then
            log_info "Pre-flight check: $(basename "$vault")";
            (
                cd "$vault" || exit;
                local stashed=0;
                if [[ -n $(git status --porcelain) ]]; then # Check for dirty state
                    log_info "  Unstaged changes detected. Stashing...";
                    git stash push --include-untracked -m "obsync-preflight" --quiet; # Include untracked files
                    stashed=1;
                fi;

                log_info "  Pulling remote changes...";
                if ! git pull --no-rebase --quiet; then # Pull using explicit --no-rebase
                    log_warn "  Pull failed (Network or Conflict). Continuing with local files.";
                fi;

                if [[ $stashed -eq 1 ]]; then # Restore stashed changes
                    log_info "  Restoring local changes...";
                    git stash pop --quiet || log_warn "  Conflict during stash pop. Please check git status.";
                fi;
            )
        else
            log_warn "Skipping non-git vault: $vault";
        fi;
    done;
}

run_watcher() {
    log_info "Watcher active (Timeout Mode: ${DEBOUNCE_SECONDS}s)";
    while kill -0 "$OBSIDIAN_PID" 2>/dev/null; do # Loop while Obsidian is running
        if inotifywait -r -e close_write -e moved_to --exclude "$EXCLUDE_PATTERN" "${VAULTS[@]}" -qq; then # Block until first change
            while true; do # Cooldown loop
                if ! kill -0 "$OBSIDIAN_PID" 2>/dev/null; then return; fi;
                if ! inotifywait -r -e close_write -e moved_to --exclude "$EXCLUDE_PATTERN" -t "$DEBOUNCE_SECONDS" "${VAULTS[@]}" -qq; then # Wait for silence
                    for vault in "${VAULTS[@]}"; do
                        git_sync "$vault" "Obsync $(date '+%H:%M')";
                    done;
                    break; # Timeout reached, back to primary loop
                fi;
            done;
        fi;
    done;
}

cleanup() {
    if [[ -n "${WATCHER_BG_PID:-}" ]]; then # Ensure all child processes of watcher and main script are killed
        pkill -P "$WATCHER_BG_PID" inotifywait 2>/dev/null || true;
        kill "$WATCHER_BG_PID" 2>/dev/null || true;
    fi;
    pkill -P $$ inotifywait 2>/dev/null || true;
}

# --- MAIN ---

if [[ "${1:-}" == "--install" ]]; then # Handle --install flag
    install_desktop_entry;
    exit 0;
fi;

if pgrep -x obsidian > /dev/null || pgrep -f '/obsidian/app\.asar' > /dev/null; then
    log_info "Obsidian is already running. Forwarding launch arguments...";
    obsidian "$@";
    exit $?;
fi;

trap cleanup EXIT;

check_prerequisites;
discover_vaults;
preflight_sync;

log_info "Launching Obsidian...";
obsidian "$@" &
OBSIDIAN_PID=$!;

run_watcher &
WATCHER_BG_PID=$!;

wait "$OBSIDIAN_PID";

log_info "Obsidian closed. Final sync...";
kill "$WATCHER_BG_PID" 2>/dev/null || true;
wait "$WATCHER_BG_PID" 2>/dev/null || true;

for vault in "${VAULTS[@]}"; do
    git_sync "$vault" "Obsync Obsend: $(date '+%Y-%m-%d %H:%M')";
done;

notify-send "Obsidian Sync" "All vaults synced." --icon=obsidian;
log_info "Done.";
