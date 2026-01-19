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
readonly OBSIDIAN_CONFIG="${HOME}/.config/obsidian/obsidian.json"
readonly DEBOUNCE_SECONDS=60
readonly SCRIPT_NAME="obsync"

# --- GLOBAL STATE ---
declare -a VAULTS=()
OBSIDIAN_PID=""

# --- LOGGING ---
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[${SCRIPT_NAME}]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[${SCRIPT_NAME}]${NC} $*"; }
log_error() { echo -e "${RED}[${SCRIPT_NAME}]${NC} $*" >&2; }

# --- CORE FUNCTIONS ---

install_desktop_entry() {
    log_info "Installing desktop entry..."
    
    # Get absolute path to this script
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    
    # Check if system desktop entry exists
    local system_desktop="/usr/share/applications/obsidian.desktop"
    if [[ ! -f "$system_desktop" ]]; then
        log_error "System Obsidian desktop entry not found at $system_desktop"
        log_error "Please install Obsidian first."
        exit 1
    fi
    
    # Create local applications directory if it doesn't exist
    mkdir -p "${HOME}/.local/share/applications"
    
    local local_desktop="${HOME}/.local/share/applications/obsidian.desktop"
    
    # Copy system desktop entry
    cp "$system_desktop" "$local_desktop"
    
    # Update Exec line to point to this script
    sed -i "s|^Exec=.*|Exec=$script_path|" "$local_desktop"
    
    # Update desktop database (if command exists)
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
    fi
    
    log_info "Desktop entry installed successfully!"
    log_info "Your DE will now launch $script_path when you click the Obsidian launcher."
    log_info "The local desktop entry in ~/.local/share/applications/ overrides the system one."
}

check_prerequisites() {
    local missing=()
    for cmd in inotifywait jq obsidian git notify-send; do
        if ! command -v "$cmd" &> /dev/null; then missing+=("$cmd"); fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing: ${missing[*]}. Install: sudo apt install inotify-tools jq git libnotify-bin"
        exit 1
    fi
    
    if [ ! -f "$OBSIDIAN_CONFIG" ]; then
        log_error "Config not found: $OBSIDIAN_CONFIG"
        exit 1
    fi
}

discover_vaults() {
    log_info "Discovering vaults..."
    # Robust jq parsing for both simple paths and vault objects
    local paths
    paths=$(jq -r '.vaults // {} | to_entries[] | .value.path // .value' "$OBSIDIAN_CONFIG" 2>/dev/null)
    
    while IFS= read -r path; do
        if [[ -n "$path" && -d "$path" ]]; then
            VAULTS+=("$path")
        fi
    done <<< "$paths"

    if [ ${#VAULTS[@]} -eq 0 ]; then
        log_error "No vaults found."
        exit 1
    fi
    log_info "Found ${#VAULTS[@]} vault(s)."
}

git_sync() {
    local vault_path="$1"
    local msg="$2"
    
    if [[ ! -d "$vault_path/.git" ]]; then return; fi
    
    # Run in subshell to preserve current directory
    (
        cd "$vault_path" || exit
        if [[ -n $(git status --porcelain) ]]; then
            log_info "Syncing $(basename "$vault_path")..."
            git add .
            git commit -m "$msg" --quiet
            
            # Push (Fail silently if no internet/remote, we will try again later)
            if git remote | grep -q .; then
                git push --quiet || log_warn "Push failed (Offline?)"
            fi
        fi
    )
}

preflight_sync() {
    for vault in "${VAULTS[@]}"; do
        if [[ -d "$vault/.git" ]]; then
            log_info "Pre-flight check: $(basename "$vault")"
            
            # Go into the vault directory
            (
                cd "$vault" || exit
                
                # 1. Check for dirty state
                local stashed=0
                if [[ -n $(git status --porcelain) ]]; then
                    log_info "  Unstaged changes detected. Stashing..."
                    git stash push -m "obsync-preflight" --quiet
                    stashed=1
                fi

                # 2. Pull
                log_info "  Pulling remote changes..."
                if ! git pull --rebase --quiet; then
                    log_warn "  Pull failed (Network or Conflict). Continuing with local files."
                fi

                # 3. Restore changes if we stashed them
                if [[ $stashed -eq 1 ]]; then
                    log_info "  Restoring local changes..."
                    # Pop triggers merge if necessary. If conflict, git warns user.
                    git stash pop --quiet || log_warn "  Conflict during stash pop. Please check git status."
                fi
            )
        else
            log_warn "Skipping non-git vault: $vault"
        fi
    done
}

# --- THE WATCHER LOGIC (The "Timeout" Method) ---
run_watcher() {
    log_info "Watcher active (Timeout Mode: ${DEBOUNCE_SECONDS}s)"
    
    # Loop while Obsidian is running
    while kill -0 "$OBSIDIAN_PID" 2>/dev/null; do
        
        # 1. BLOCK until FIRST change
        # -qq: absolute silence
        # -e: only watch write/move events
        if inotifywait -r -e close_write -e moved_to --exclude '\.git/' "${VAULTS[@]}" -qq; then
            
            # 2. COOLDOWN LOOP
            while true; do
                # Check app life
                if ! kill -0 "$OBSIDIAN_PID" 2>/dev/null; then return; fi

                # Wait for silence (Timeout)
                if ! inotifywait -r -e close_write -e moved_to --exclude '\.git/' -t "$DEBOUNCE_SECONDS" "${VAULTS[@]}" -qq; then
                    # Exit Code 2 = Timeout Reached = Silence
                    for vault in "${VAULTS[@]}"; do
                        git_sync "$vault" "Obsync $(date '+%H:%M')"
                    done
                    break # Go back to Step 1
                fi
                # Exit Code 0 = Change Detected = Reset Timer (Loop continues)
            done
        fi
    done
}

cleanup() {
    # Ensure all child processes (inotifywait) are killed
    # pkill -P $$ is safer than managing specific PIDs
    pkill -P $$ inotifywait 2>/dev/null
}

# --- MAIN ---

# Handle --install flag
if [[ "${1:-}" == "--install" ]]; then
    install_desktop_entry
    exit 0
fi

trap cleanup EXIT

check_prerequisites
discover_vaults
preflight_sync

log_info "Launching Obsidian..."
obsidian &
OBSIDIAN_PID=$!

# Run watcher in foreground (No & needed because we want to block until Obsidian dies)
# Actually, we need to handle Obsidian closing.
# Strategy: Run watcher in background, wait for Obsidian PID in foreground.
run_watcher &
WATCHER_BG_PID=$!

wait "$OBSIDIAN_PID"

# Shutdown
log_info "Obsidian closed. Final sync..."
kill "$WATCHER_BG_PID" 2>/dev/null
wait "$WATCHER_BG_PID" 2>/dev/null

for vault in "${VAULTS[@]}"; do
    git_sync "$vault" "Obsync Obsend: $(date '+%Y-%m-%d %H:%M')"
done

notify-send "Obsidian Sync" "All vaults synced." --icon=obsidian
log_info "Done."
