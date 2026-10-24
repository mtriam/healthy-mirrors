# healthy-mirrors

Checks mirror health and automatically keeps only healthy mirrors active, reducing the risk of partial upgrades caused by mirrors that are out of sync.

## What it does

The `hm` script reads the mirror lists included via `/etc/pacman.conf` and checks the current CachyOS and Arch Linux mirror status using their respective APIs.

For CachyOS, it checks mirror synchronization separately for the `x86_64`, `x86_64_v3`, and `x86_64_v4` architectures. A mirror is considered healthy for a given architecture only if all reported checks for that architecture are synchronized.

For Arch Linux mirrors, it keeps only active HTTPS mirrors that are fully synchronized (`completion_pct = 1.0`), have a reported synchronization time, and have a delay of less than one hour.

The script updates the mirrorlist files **in place, without creating a backup**, by commenting out unhealthy mirrors with a `#UH#` marker while leaving healthy mirrors active. It removes existing markers before re-evaluating the mirrors, so the status is refreshed on each run. Use `hm --clean` to undo the markers.

After processing the mirror lists, it prints a summary showing the number of active and disabled mirrors for each list. If any repository has no active mirrors, it prints a warning and exits with a non-zero status.

## hm-daemon

An optional systemd service that uses Linux fanotify to hold attempts to open `/etc/pacman.conf` (and other configured files). When a relevant process opens the file, the daemon runs `hm` first and releases the waiting `open()` once the script finishes, so the program reads the already updated mirror lists. No wrapper or alias is needed.

**What triggers `hm`**

- `pacman` with a sync or upgrade operation (`-S*`, `-U`). Other operations, such as `pacman -Q`, `-T` or `--database`, do not trigger it.
- Processes whose name matches `SHELLY_RE` (default: `shelly.*`).
- AUR helpers matching `HELPERS_RE` (default: `yay|paru|pikaur|trizen|octopi`), only when started without options or with a sync/upgrade operation.

**Behavior**

- While `hm` is running, other processes opening the monitored files are held as well, so nothing reads the mirror lists before they are updated. From the user's side, `pacman` simply waits at startup without any message.
- Requests from the daemon itself and from `hm` and its subprocesses are always allowed through, to avoid deadlocks.
- A cooldown (default 60 s) prevents `hm` from running repeatedly.
- `hm` is killed if it runs longer than the timeout (default 30 s).

- **If `hm` fails or times out, the waiting program is still released and continues with the existing mirror lists.**
- If the daemon stops, the kernel releases all held requests, so `pacman` cannot hang permanently.

**Security**

The daemon runs as root and executes `/usr/local/bin/hm` as root. `hm` and its parent directories must be owned by root and not writable by group or others; `install-daemon.sh` checks this. The service is hardened (`ProtectSystem=strict`, `NoNewPrivileges`, a minimal capability set, and write access only to the directories of mirrorlists included from `pacman.conf`).

**Configuration**

Set environment variables with a systemd drop-in:

```bash
sudo systemctl edit hm-daemon.service
```

```ini
[Service]
Environment="COOLDOWN=600"
Environment="HELPERS_RE=yay|paru"
```

| Variable | Default | Meaning |
|---|---|---|
| `HM` | `/usr/local/bin/hm` | Script to run |
| `HM_TIMEOUT` | `30` | Seconds before `hm` is killed |
| `COOLDOWN` | `60` | Minimum seconds between `hm` runs |
| `WATCH` | `/etc/pacman.conf` | Files to monitor (colon-separated) |
| `SHELLY_RE` | `shelly.*` | Process names that always trigger `hm` |
| `HELPERS_RE` | `yay\|paru\|pikaur\|trizen\|octopi` | AUR helpers and frontends that trigger `hm` when run bare or with a sync/upgrade operation |

## Requirements

`hm`:

- `bash`, `curl`, `jq`, `sed`, `grep`, `cmp` (diffutils)
- `sudo` (only when mirrorlist files need to be updated and you are not root)

`hm-daemon` (optional):

- `systemd`
- `python3`
- a kernel with fanotify permission events (`CONFIG_FANOTIFY_ACCESS_PERMISSIONS`)

## Install

```bash
git clone https://github.com/mtriam/healthy-mirrors.git
cd healthy-mirrors
./install.sh          # installs hm to /usr/local/bin
./install-daemon.sh   # optional: installs and starts hm-daemon.service
```

`install-daemon.sh` requires `hm` to be already installed in `/usr/local/bin`. It can be run again to update the service.

## Update

```bash
cd healthy-mirrors
git pull --ff-only
./install.sh          # updates hm in /usr/local/bin
./install-daemon.sh   # optional: updates and restarts hm-daemon.service
```

- `install-daemon.sh` can be run repeatedly. It replaces `/usr/local/bin/hm-daemon`, regenerates the service unit and restarts the service.
- Restarting the daemon is safe: if it stops, the kernel releases all held `open()` requests, so `pacman` is never blocked. In the worst case, a `pacman` started during the restart runs with the existing mirror lists.
- Settings made with a systemd drop-in (`/etc/systemd/system/hm-daemon.service.d/`) are kept.

## Uninstall

Remove the markers first, otherwise commented-out mirrors stay disabled:

```bash
hm --clean
./install-daemon.sh --remove   # if the daemon is installed
sudo rm /usr/local/bin/hm
```

`--remove` stops and removes `hm-daemon.service` and `/usr/local/bin/hm-daemon`. A drop-in created with `systemctl edit` is left in `/etc/systemd/system/hm-daemon.service.d/`; remove it manually if needed.

## Diagnostics

To follow the daemon logs in real time:

```bash
journalctl -fu hm-daemon.service
```

Each `open()` is logged with the process name, command line and whether it triggered `hm` (`trigger=True/False`, `cooldown=True/False`).

## Usage

**If the daemon is installed and running, no additional action is needed.**

It runs `hm` automatically before matching programs read `pacman.conf` and the mirror lists.

### Manual use

Without the daemon, run `hm` manually before using the mirror lists, or use the `up` shell function described below.

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

The `up` function refreshes the healthy mirror list with `hm` and then runs a system upgrade, optionally installing the given packages. If `hm` fails (for example, a repository has no active mirrors), the upgrade is not started.

#### zsh

```zsh
echo 'up() { hm && sudo pacman -Syu "$@"; }' >> ~/.zshrc
source ~/.zshrc
```

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
