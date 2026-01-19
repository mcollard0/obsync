# obsync

**obsync** is a lightweight Bash script wrapper for [Obsidian](https://obsidian.md/) on Linux that provides automated, debounced Git syncing for all your vaults.

## Features

*   **Automated Syncing**:   Automatically commits and pushes changes to your git remote.
*   **Multi-Vault Support**: Discovers all vaults configured in `~/.config/obsidian/obsidian.json`.
*   **Debounced Saves**:     Waits for a cooldown period (default 60s) after the last edit before syncing, preventing excessive commits while typing.
*   **Pre-Flight Check**:    Pulls latest changes (`git pull --rebase`) on startup to ensure your local vault is up-to-date.
*   **Graceful Shutdown**:   Performs a final sync when Obsidian is closed.
*   **Notifications**:       Sends desktop notifications upon successful syncs.
*   **Install Helper**:      Basic installation shortcut creator, so when you run Obsidian, it runs the sync as well. 

## Prerequisites

*   Linux environment
*   `git`
*   `inotify-tools` (for file watching)
*   `jq` (for parsing Obsidian config)
*   `libnotify-bin` (for `notify-send`)

### Installation

1.  Install dependencies:
    ```bash
    sudo apt install git inotify-tools jq libnotify-bin
    ```

2.  Clone this repository:
    ```bash
    git clone https://github.com/mcollard0/obsync.git
    cd obsync
    ```

3.  Make the script executable:
    ```bash
    chmod +x obsync_v1.sh
    ```

4a. (Optional) Run installer 
    ```bash
    ./obsync_v1.sh --install
    ```

4b. (SuperOptional) Symlink to your path:
    ```bash
    sudo ln -s $(pwd)/obsync_v3.sh /usr/local/bin/obsync
    ```

## Usage

Simply nstall Obsidian helper in step 4A above or,

Simply run the script instead of launching Obsidian directly to test it out before committing:

```bash
./obsync_v1.sh
```

## Configuration

The script assumes your Obsidian configuration is located at `~/.config/obsidian/obsidian.json`.

Ensure your vaults are initialized as git repositories and have a remote configured:

```bash
cd /path/to/your/vault
git init
git remote add origin <your-repo-url>
```

## License

MIT
