Implementation Plan for obsync:

Prompt to generate the script:

"Create a Bash script to act as a wrapper for Obsidian on Linux. The script must handle automated Git syncing for all Obsidian vaults.

Prerequisites:

The script relies on inotify-tools for file watching and jq for parsing JSON.

Assume standard Obsidian config location: ~/.config/obsidian/obsidian.json.

Script Logic & Flow:

Setup & Discovery:

Parse obsidian.json to find all vault paths.

Store them in an array.

Pre-Flight (Startup):

Iterate through each vault.

Check if it is a git repo.

Run git pull --rebase to ensure local files are up to date.

Launch Application:

Start obsidian as a background process (&).

Capture its Process ID (PID).

The Watcher Loop (Background Function):

While the Obsidian PID is running:

Use inotifywait in recursive monitor mode (-m -r) on the vault directories.

Listen for close_write and moved_to events.

Debounce Logic:

When an event triggers, start a 'cooldown' timer (e.g., 60 seconds).

If another event triggers before 60s, reset the timer (wait for the user to stop typing).

Once the 60s timer expires without new events:

Run git add .

Run git commit -m "Auto-save: $(date)"

(Optional) Run git push.

Shutdown Sequence:

Wait for the Obsidian PID to exit (using wait $PID).

Immediately run a final git add ., git commit -m "Session end", and git push.

Output a notification (using notify-send) confirming the sync is complete.

Constraints:

Handle spaces in file paths correctly.

Do not push if the commit fails (empty commit)."
