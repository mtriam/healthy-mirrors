# healthy-mirrors

Checks mirror health and automatically keeps only healthy mirrors active, reducing the risk of partial upgrades caused by mirrors that are out of sync.

## Quick start

Install `hm` and enable automatic mirror checks:

```bash
git clone https://github.com/mtriam/healthy-mirrors.git
cd healthy-mirrors && ./install.sh && ./install-daemon.sh
```

That's it! `hm-daemon` automatically checks mirror health before matching package-management operations. It disables unhealthy or out-of-sync mirrors by commenting them out with a `#UH#` marker, helping reduce the risk of partial upgrades.

No aliases or wrappers are needed.

Example output of hm:  
![Example output of hm](docs/output.png)

See [Usage](#usage) for manual operation and [hm-daemon](#hm-daemon) for details and configuration.

## What it does

The `hm` script reads existing mirror-list files included via `/etc/pacman.conf` (including ordinary shell-glob patterns) and checks the current CachyOS and Arch Linux mirror status using their respective APIs. Non-absolute or missing `Include` entries are skipped; if no existing mirror-list file is found, the script fails.

For CachyOS, it checks mirror synchronization separately for the `x86_64`, `x86_64_v3`, and `x86_64_v4` architectures. A mirror is considered healthy for a given architecture only if all reported checks for that architecture are synchronized.

For Arch Linux mirrors, it keeps only active HTTPS mirrors that are fully synchronized (`completion_pct = 1.0`), have a reported synchronization time, and have a delay of less than one hour.

The script updates the mirrorlist files by commenting out unhealthy mirrors with a `#UH#` marker while leaving healthy mirrors active. It removes existing markers before re-evaluating the mirrors, so the status is refreshed on each run. Use `hm --clean` to remove the markers.

Updates are transactional: every changed file is first staged and backed up next to the original (`.hm-stage.*`, `.hm-backup.*` in the mirrorlist directory), checked against an invariant (only the `#UH#` marker at the start of a line may change), and then replaced atomically with `mv`. If any step fails, files already replaced are restored from their backups. Nothing is written if any repository would end up without an active mirror. API responses and mirror URLs are validated, and API data is never interpreted as `sed` or regex syntax. If `hm` is killed in the middle of an update (for example by the daemon timeout), leftover `.hm-stage.*` / `.hm-backup.*` files may remain and can be removed manually.

After processing the mirror lists, it prints a summary showing the number of active and disabled mirrors for each list. If any repository has no active mirrors, it prints a warning and exits with a non-zero status.

## hm-daemon

An optional systemd service that uses Linux fanotify to hold attempts to open `/etc/pacman.conf` (and other configured files). When a relevant process opens the file, the daemon runs `hm` first and releases the waiting `open()` once the script finishes, so the program reads the already updated mirror lists. No wrapper or alias is needed.

**What triggers `hm`**

- `pacman` with a mirror-using operation: sync or upgrade (`-S*`, `-U`), or file-database refresh (`-Fy` / `--files --refresh`). Other operations, such as `pacman -Q`, `-T` or `--database`, do not trigger it.
- Processes whose name matches `SHELLY_RE` (default: `shelly.*`).
- AUR helpers matching `HELPERS_RE` (default: `yay|paru|pikaur|trizen|octopi`), only when started without options or with a sync/upgrade operation.

**Behavior**

- While `hm` is running, other processes opening the monitored files are held as well, so nothing reads the mirror lists before they are updated. From the user's side, `pacman` simply waits at startup without any message.
- Requests from the daemon itself and from `hm` and its subprocesses are always allowed through, to avoid deadlocks.
- A cooldown (default 60 s) prevents `hm` from running repeatedly.
- `hm` is killed if it runs longer than the timeout (default 30 s).
- If a watched file is replaced (editor, `sed -i`, package update), the daemon re-marks the new file immediately via an inotify watch on its directory. A slow periodic check (`RECHECK`) is kept as a safety net. If a watched path is a symlink, replacement of its target is found only by that periodic check.
- On stop (`SIGTERM`/`SIGINT`) the daemon starts no new `hm` runs, lets a running `hm` finish for up to `STOP_GRACE` seconds, releases all held requests and exits. `hm` defers `SIGTERM`/`SIGINT`/`SIGHUP` while it replaces mirrorlists, so a stop cannot interrupt an update halfway. If `hm` does not finish in time, it and its child processes are killed.
- At most `MAX_HELD` requests are held while `hm` runs; further ones are let through, so a flood of local processes cannot exhaust the daemon's file descriptors.
- Unrecoverable `fanotify` errors make the daemon log the reason and exit with a non-zero status (systemd restarts it, and the kernel releases pending requests).


- **If `hm` fails or times out, the waiting program is still released and continues with the existing mirror lists.**
- If the daemon stops, the kernel releases all held requests, so `pacman` cannot hang permanently.

**Security**

The daemon runs as root and executes `/usr/local/bin/hm` as root. `hm` and its parent directories must be owned by root and not writable by group or others; `install-daemon.sh` checks this. The service is hardened (`ProtectSystem=strict`, `NoNewPrivileges`, a minimal capability set, and write access only to the directories of mirrorlists included from `pacman.conf`).
Process names are not authenticated: any local process named `pacman` (or matching `SHELLY_RE`/`HELPERS_RE`) that opens `pacman.conf` with a sync operation can trigger `hm`, at most once per `COOLDOWN`. This gives no privileges, because `hm` takes no input from the triggering process, but it can delay other `pacman` runs for the duration of one `hm` run.

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
| `RECHECK` | `600` | Safety-net check (seconds) that every watched file is still marked and the directory watches exist; `0` disables it. Replacements are normally detected immediately via inotify |
| `MAX_HELD` | `256` | Maximum number of `open()` calls held while `hm` runs; further ones are let through |
| `STOP_GRACE` | `5` | Seconds a running `hm` may finish when the service is stopped |

## Requirements

All dependencies are already satisfied on a default CachyOS installation.

`hm`:

- `bash`, `curl`, `jq`, `sed`, `grep`, `cmp`, `awk`, `mktemp`, `mv`, `cp`, `timeout`
- `sudo` (only when mirrorlist files need to be updated and you are not root)

`hm-daemon` (optional):

- `systemd`
- `python3`
- a kernel with fanotify permission events (`CONFIG_FANOTIFY_ACCESS_PERMISSIONS`)

## Error notifications

When `hm` is not run in a terminal (for example by `hm-daemon`, or from a keybinding), errors are also shown as desktop notifications: failed downloads, unparsable API responses, failed `sudo` authentication and repositories without any active mirror. In a terminal the error is printed as usual and no notification is sent.

- When run as root (by the daemon), `hm` notifies every active user session via `notify-send`, using `setpriv` to switch to that user. Delivery results and failures are written to the journal (`journalctl -u hm-daemon.service`).
- Requires `notify-send` (`libnotify`), `setpriv` and `loginctl` (`util-linux`, `systemd`), and a running notification daemon in the user session.
- To allow this, the service unit uses `ProtectHome=read-only` (instead of `yes`) and additionally keeps `CAP_SETUID` and `CAP_SETGID`.
- Control: `HM_NOTIFY=auto|always|never` (default `auto`). Send a test notification with `hm --notify-test`.

## Install

```bash
git clone https://github.com/mtriam/healthy-mirrors.git
cd healthy-mirrors
./install.sh          # installs hm to /usr/local/bin
./install-daemon.sh   # optional: installs and starts hm-daemon.service
```

Both installers use only files from the local checkout; they never download executable files. `install-daemon.sh` requires `hm` to be already installed in `/usr/local/bin`, validates the local daemon source as Python, and checks that `hm` and every path component up to `/` are root-owned and not group/world-writable. It can be run again to update the service. Use `SRC=/path/to/hm-daemon ./install-daemon.sh` to install a daemon from another local path.

## Update

```bash
cd healthy-mirrors
git pull --ff-only
./install.sh          # updates hm in /usr/local/bin
./install-daemon.sh   # optional: updates and restarts hm-daemon.service
```

- `install.sh` and `install-daemon.sh` install files as `root:root` with mode `0755`.
- `install-daemon.sh` can be run repeatedly. It replaces `/usr/local/bin/hm-daemon`, regenerates the service unit using the resolved `Include` directories as writable paths, and restarts the service.
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

## Tests

`test-hm-daemon.sh` exercises `hm-daemon` against a scratch file in `/tmp`. It never touches `/etc/pacman.conf`, the installed service or the mirrorlists: it starts its own daemon instance (with `COOLDOWN=0`, `RECHECK=0` and a stub instead of `hm`) and uses a symlink named `pacman` to `cat` as a fake client.

```bash
./test-hm-daemon.sh                      # uses ./hm-daemon
./test-hm-daemon.sh /path/to/hm-daemon
```

The script re-runs itself with `sudo` (fanotify permission events need root). It needs `python3`, `awk`, `pkill`/`pgrep` (procps-ng), `timeout` and coreutils, plus a kernel with fanotify permission events.

| # | What is checked |
|---|---|
| 1 | The mark follows a replaced file (`mv`, `sed -i`, `rm` + create, `ln -f`, in-place write): after each change a fake `pacman --sync` still triggers `hm` |
| 2 | `SIGTERM` while a request is held: the request is released after `STOP_GRACE`, the daemon exits with code 0 and the stub `hm` is killed |
| 3 | `SIGKILL` of the daemon while a request is held: the kernel lets the request through |
| 4 | `MAX_HELD`: with a limit of 5, exactly 5 of 12 concurrent requests are held, the rest pass |
| 5 | `hm` cannot be started: the request is not left blocked and the error is logged |

A successful run ends with `passed: 15, failed: 0` and exit status 0. Test 1 depends on timing (the new inode has to be re-marked before the fake client opens the file; a 0.2 s margin is used). If a single case of test 1 fails on a heavily loaded system, run the script again before investigating.

The script does **not** cover `hm` itself (mirror evaluation, transactional updates), desktop notifications or the systemd sandbox. Check those with:

```bash
hm --notify-test                  # notification path of a regular user
sudo hm                           # real run; then: grep -c '^#UH#' /etc/pacman.d/*mirrorlist*
sudo hm --clean                   # removes the markers again
journalctl -fu hm-daemon.service  # watch the daemon, e.g. while running `pacman -Ss foo`
```

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
