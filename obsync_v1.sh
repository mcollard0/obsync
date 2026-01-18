#!/bin/bash

# ==============================================================================
# Obsidian Git Wrapper (Linux)
# ------------------------------------------------------------------------------
# 1. Discovers vaults from obsidian.json
# 2. Pulls remote changes on startup
# 3. Launches Obsidian
# 4. Watches for file changes (debounced) to auto-commit
# 5. Pushes on exit
# ==============================================================================

# --- CONFIGURATION ---
OBSIDIAN_CONFIG="$HOME/.config/obsidian/obsidian.json"
DEBOUNCE_SECONDS=60  # Wait this long after typing stops before committing
SYNC_MSG_PREFIX="Auto-save"

# --- DEPENDENCY CHECK ---
for cmd in git jq inotifywait notify-send; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# --- FUNCTIONS ---

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

notify() {
    notify-send "Obsidian Sync" "$1" --icon=obsidian
}

get_vaults() {
    if [[ -f "$OBSIDIAN_CONFIG" ]]; then
        # Parse obsidian.json for vault paths
        jq -r '.vaults | to_entries[] | .value.path' "$OBSIDIAN_CONFIG"
    else
        log "Warning: Config not found at $OBSIDIAN_CONFIG. Please edit script to manually add paths."
        exit 1
    fi
}

sync_vault() {
    local vault_path="$1"
    local message="$2"
    
    cd "$vault_path" || return

    if [[ ! -d ".git" ]]; then
        return
    fi

    # Check for changes
    if [[ -n $(git status --porcelain) ]]; then
        git add .
        git commit -m "$message: $(date '+%Y-%m-%d %H:%M')" --quiet
        log "Changes committed in $(basename "$vault_path")."
        
        # Optional: Push immediately or wait for exit? 
        # Uncomment below to push on every auto-save (can be slow)
        # git push --quiet &
    fi
}

push_vault() {
    local vault_path="$1"
    cd "$vault_path" || return
    if [[ -d ".git" ]]; then
        log "Pushing $(basename "$vault_path")..."
        git push --quiet
    fi
}

# --- MAIN EXECUTION ---

# 1. DISCOVERY & PRE-FLIGHT
log "Scanning for vaults..."
mapfile -t VAULTS < <(get_vaults)

for vault in "${VAULTS[@]}"; do
    if [[ -d "$vault/.git" ]]; then
        log "Syncing (Pull) $vault..."
        git -C "$vault" pull --rebase --quiet
    fi
done

# 2. LAUNCH OBSIDIAN
log "Launching Obsidian..."
obsidian &
OBSIDIAN_PID=$!

# 3. WATCHER LOOP (Background Process)
(
    # We use a temporary file to track the "last change time" for debouncing
    # simpler than managing background sleep PIDs in a loop
    WATCH_TMP=$(mktemp)
    
    # Start inotifywait in monitor mode
    # -m: monitor indefinitely
    # -r: recursive
    # -e: events to watch (close_write is when a file is saved)
    # --exclude: ignore .git folder to prevent loops
    inotifywait -m -r -e close_write -e moved_to --exclude '\.git/' --format '%w%f' "${VAULTS[@]}" 2>/dev/null | while read file; do
        # When a file changes, update the timestamp on our tracker file
        touch "$WATCH_TMP"
    done &
    
    INOTIFY_PID=$!

    # The Debounce Checker Loop
    LAST_COMMIT_TIME=$(date +%s)
    
    while kill -0 $OBSIDIAN_PID 2>/dev/null; do
        sleep 5
        
        # Check if the tracker file exists and get its modification time
        if [[ -f "$WATCH_TMP" ]]; then
            LAST_CHANGE=$(stat -c %Y "$WATCH_TMP")
            NOW=$(date +%s)
            DIFF=$((NOW - LAST_CHANGE))
            COMMIT_DIFF=$((NOW - LAST_COMMIT_TIME))

            # Logic: 
            # If (Time since last file change > DEBOUNCE) AND (We haven't committed this change yet)
            if [[ $DIFF -ge $DEBOUNCE_SECONDS ]] && [[ $LAST_CHANGE -gt $LAST_COMMIT_TIME ]]; then
                log "Silence detected ($DEBOUNCE_SECONDS s). Triggering Auto-save..."
                
                for vault in "${VAULTS[@]}"; do
                    sync_vault "$vault" "$SYNC_MSG_PREFIX"
                done
                
                LAST_COMMIT_TIME=$(date +%s)
            fi
        fi
    done

    # Cleanup watcher when Obsidian dies
    kill $INOTIFY_PID 2>/dev/null
    rm "$WATCH_TMP" 2>/dev/null
) &

WATCHER_PID=$!

# 4. WAIT FOR OBSIDIAN TO CLOSE
wait $OBSIDIAN_PID

# 5. SHUTDOWN SEQUENCE
log "Obsidian closed. Performing final sync..."
kill $WATCHER_PID 2>/dev/null

for vault in "${VAULTS[@]}"; do
    sync_vault "$vault" "Session End"
    push_vault "$vault"
done

notify "Vaults synced and pushed."
log "Done."
