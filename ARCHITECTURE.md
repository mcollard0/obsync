# obsync - Implementation Architecture

## Overview
**obsync** is a Bash script wrapper for Obsidian on Linux that provides **automated Git syncing** for all Obsidian vaults.

---

## Prerequisites

The script requires:
- **`inotify-tools`** - for file watching
- **`jq`** - for JSON parsing
- **Standard Obsidian config location**: `~/.config/obsidian/obsidian.json`

---

## Script Logic & Flow

### 1. Setup & Discovery

- Parse `obsidian.json` to find all vault paths
- Store them in an array

### 2. Pre-Flight (Startup)

- Iterate through each vault
- Check if it is a git repo
- Run `git pull --rebase` to ensure local files are up to date

### 3. Launch Application

- If **Obsidian** is already running, detect either an `obsidian` process or its Electron `/obsidian/app.asar` process, invoke `obsidian "$@"`, and exit. This forwards URI handler arguments (such as `obsidian://open?...`) to the existing instance without a second watcher or Git pre-flight.
- Otherwise, start **obsidian** as a background process with the original arguments (`obsidian "$@" &`).
- Capture its **Process ID (PID)** and begin the sync watcher lifecycle.
- The installed `obsidian.desktop` launcher uses `%U` in `Exec` so desktop environments pass incoming `obsidian://` URIs to the wrapper.

### 4. The Watcher Loop (Background Function)

While the Obsidian PID is running:

- Use **`inotifywait`** in recursive monitor mode (`-m -r`) on the vault directories
- Listen for `close_write` and `moved_to` events

#### Debounce Logic:

1. When an event triggers, start a **cooldown timer** (e.g., 60 seconds)
2. If another event triggers before 60s, **reset the timer** (wait for the user to stop typing)
3. Once the 60s timer expires without new events:

```bash
git add .
git commit -m "Auto-save: $(date)"
```

4. *(Optional)* Run `git push`

### 5. Shutdown Sequence

- Wait for the Obsidian PID to exit (using `wait $PID`)
- Immediately run a final:
  - `git add .`
  - `git commit -m "Session end"`
  - `git push`
- Output a **notification** (using `notify-send`) confirming the sync is complete

---

## Constraints

- ✅ Handle **spaces in file paths** correctly
- ✅ Do **not push** if the commit fails (empty commit)

---

## Additional QOL Improvements

- **Late stage**: Added a `--install` helper
- **Late stage**: Added a handler to stash and pop "sando" when changes are made before the program is installed, files edited outside Obsidian, and so on

---

*-Michael, yes that Michael. I'm sorry too. Please stop sending pizza. It's getting weird. The delivery guy is my best man at the wedding.*

