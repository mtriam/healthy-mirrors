# healthy-mirrors

Checks mirror health and automatically keeps only healthy mirrors active, helping reduce the risk of partial upgrades and broken system states.

## What it does

The script reads the mirror lists included via /etc/pacman.conf and checks the current CachyOS and Arch Linux mirror status using their respective APIs.

For CachyOS, it checks mirror synchronization separately for the x86_64, x86_64_v3, and x86_64_v4 architectures. A mirror is considered healthy for a given architecture only if all reported checks for that architecture are synchronized.

For Arch Linux mirrors, it keeps only active HTTPS mirrors that are fully synchronized (completion_pct = 1.0), have a reported synchronization time, and have a delay of less than one hour.

The script updates the mirrorlist files by commenting out unhealthy mirrors with a #UH# marker while leaving healthy mirrors active. It removes existing markers before re-evaluating the mirrors, allowing their status to be updated on each run.

After processing the mirror lists, it prints a summary showing the number of active and disabled mirrors for each list. If any repository has no active mirrors, it prints a warning and exits with a non-zero status.

## hm-daemon

An optional systemd service that uses Linux fanotify to monitor attempts to open /etc/pacman.conf and other configured files. When a relevant operation is detected, it temporarily holds the file-open requests, runs hm, and releases the waiting requests once the script finishes.

The daemon triggers hm before mirror-related pacman operations (-S and -U) and matching shelly processes access the monitored files. Other operations, such as querying installed packages with pacman -Q, do not trigger a mirror check.

While hm is running, additional file-open requests are held to prevent concurrent access before the mirror lists have been updated. Requests originating from the daemon itself or its hm subprocess are allowed through to avoid deadlocks.

To reduce unnecessary executions, the daemon enforces a configurable cooldown between runs and terminates hm if it exceeds the configured timeout. Both normal completion and timeout handling release the waiting file-open requests.


## Requirements

- `curl`
- `jq`
- `sed`
- `grep`
- `sudo` (only when mirrorlist files need to be updated)

## Install

Install system-wide to `/usr/local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/install-daemon.sh | bash
```

## Manual install

```bash
git clone https://github.com/mtriam/healthy-mirrors.git
cd healthy-mirrors
./install.sh
./install-daemon.sh
```

## Uninstall

```bash
sudo rm /usr/local/bin/hm  

sudo systemctl disable --now hm-daemon.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/hm-daemon.service /usr/local/bin/hm-daemon
sudo systemctl daemon-reload
```

## Diagnostics

To follow the daemon logs in real time:

```bash
journalctl -fu hm-daemon.service
```

## Usage

**If the daemon is installed and running, no additional action is needed**. It automatically runs `hm` when the mirror lists are accessed.


## Manual use

Without the daemon, run `hm` manually before using the mirror lists, or use the `up` shell functions described below.

Run:

```bash
hm
```

To remove the `#UH#` markers added by `hm`:

```bash
hm --clean
```

or:

```bash
hm -c
```

The `-c` / `--clean` option removes only the `#UH#` marker prefix from previously flagged `Server = ...` lines. It does not delete mirrors or restore a backup of the original mirrorlist files.

Both modes compare the generated result with the current file before writing changes, so an unchanged run does not ask for `sudo`.

### Shell function: `up`

The `up` function refreshes the healthy mirror list, runs a system upgrade or package installation, and then removes the `#UH#` markers using `hm -c`.

#### zsh

```zsh
echo 'up() { hm && sudo pacman -Syu "$@"; }' >> ~/.zshrc
source ~/.zshrc```

#### fish
```fish
echo 'function up; hm; and sudo pacman -Syu $argv; end' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

### Examples

Upgrade the system:

```bash
up
```

Install a package while upgrading the system:

```bash
up firefox
```
