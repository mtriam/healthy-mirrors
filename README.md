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

Updates are transactional: every changed file is first staged and backed up next to the original (`.hm-stage.*`, `.hm-backup.*` in the mirrorlist directory), checked against an invariant (only the `#UH#` marker at the start of a line may change), and then replaced atomically with `mv`. If any step fails, files already replaced are restored from their backups. Nothing is written if any repository would end up without an active mirror, so a failed run leaves the mirrorlists as they were (never half-written). API responses and mirror URLs are validated, and API data is never interpreted as `sed` or regex syntax. `SIGTERM`, `SIGINT` and `SIGHUP` received during an update are deferred until it has finished. If `hm` is killed with `SIGKILL` in the middle of an update (for example by the daemon timeout), leftover `.hm-stage.*` / `.hm-backup.*` files may remain and can be removed manually.

After processing the mirror lists, it prints a summary showing the number of active and disabled mirrors for each list. If any repository has no active mirrors, it prints a warning and exits with a non-zero status.

## Requirements

All dependencies are already satisfied on a default CachyOS installation.

`hm`:

- `bash`, `curl`, `jq`, `sed`, `grep`, `awk`, `cmp`, `mktemp`, `mv`, `cp`, `timeout`
- `sudo` (only when mirrorlist files need to be updated and you are not root)

`hm-daemon` (optional):

- `systemd`
- `python3`
- a kernel with fanotify permission events (`CONFIG_FANOTIFY_ACCESS_PERMISSIONS`)

Desktop notifications on errors (optional): `notify-send` (`libnotify`), `setpriv` and `loginctl` (`util-linux`, `systemd`), and a running notification daemon in your session.

The installers additionally use `install`, `stat` and `readlink` (coreutils); `pacman-conf` and `systemd-analyze` are used when available.

## Install

```bash
git clone https://github.com/mtriam/healthy-mirrors.git
cd healthy-mirrors
./install.sh          # installs hm to /usr/local/bin
./install-daemon.sh   # optional: installs and starts hm-daemon.service
```

Both installers use only files from the local checkout; they never download anything. Because the installed files run as root, they:

- refuse a source file that is not owned by root or by the user who ran `sudo`, or that is world-writable (group-writable only produces a warning),
- copy the file into a root-only staging directory under `/run`, validate that exact copy, install it atomically and verify the result.

`install-daemon.sh` additionally:

- requires `hm` to be installed already (run `./install.sh` first) and checks that `hm` and every path component up to `/` are root-owned, not symlinks and not group/world-writable,
- asks `hm --list` which mirrorlists exist, so that `hm` and the service sandbox agree on the writable directories,
- generates the hardened unit and **restores the previous version if the new service does not start** (it must stay up for 2 seconds without a restart).

Use `SRC=/path/to/file ./install.sh` or `SRC=/path/to/hm-daemon ./install-daemon.sh` to install from another local path.

## Update

```bash
cd healthy-mirrors
git pull --ff-only
./install.sh          # updates hm in /usr/local/bin
./install-daemon.sh   # optional: updates and restarts hm-daemon.service
```

- `install.sh` and `install-daemon.sh` install files as `root:root` with mode `0755` and can be run repeatedly.
- `install-daemon.sh` replaces `/usr/local/bin/hm-daemon`, regenerates the service unit (using the directories of the mirrorlists reported by `hm --list`) and restarts the service. If the new version does not start, the previous binary, unit and service state are restored.
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

## Usage

**If the daemon is installed and running, no additional action is needed.** It runs `hm` automatically before matching programs read `pacman.conf` and the mirror lists.

### Manual use

Without the daemon, run `hm` manually before using the mirror lists, or use the `up` shell function described below.

```bash
hm
```

| Option | Meaning |
|---|---|
| `-c`, `--clean` | Remove the `#UH#` marker prefix from previously flagged `Server = ...` lines. It does not delete mirrors or restore a backup of the original mirrorlist files |
| `--list` | Print the mirrorlist files `hm` manages (the existing files from the `Include` lines of `pacman.conf`) and exit, without network access or writes. Mirrorlists that are symlinks are not supported by `hm` |
| `--notify-test` | Send a test desktop notification and exit |
| `-h`, `--help` | Show the help message |

`--clean`, `--list` and `--notify-test` cannot be combined. Set `HM_NOTIFY=auto|always|never` to control desktop notifications on errors (default `auto`, see [Error notifications](#error-notifications)).

Both `hm` and `hm --clean` compare the generated result with the current file before writing changes, so an unchanged run does not ask for `sudo`.

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

## hm-daemon

An optional systemd service that uses Linux fanotify to hold attempts to open `/etc/pacman.conf` (and other configured files). When a relevant process opens the file, the daemon runs `hm` first and releases the waiting `open()` once the script finishes, so the program reads the already updated mirror lists. No wrapper or alias is needed.

### What triggers `hm`

- `pacman` with a mirror-using operation: sync (`-S*` / `--sync`), upgrade (`-U` / `--upgrade`) or a file-database refresh (`-F` together with `-y`, however spelled: `-Fy`, `-F -y`, `--files --refresh`, `--files -y`). Short options and the exact long names are recognized, also when a wrapper passes them separately or mixed; abbreviated long options (such as `--syn`) are not. Other operations, such as `pacman -Q`, `-T` or `--database`, do not trigger it.
- Processes whose name matches `SHELLY_RE` (default: `shelly.*`).
- AUR helpers matching `HELPERS_RE` (default: `yay|paru|pikaur|trizen|octopi`), only when started without options or with a sync/upgrade operation (recognized the same way as for `pacman`).

### Behavior

- While `hm` is running, other processes opening the monitored files are held as well, so nothing reads the mirror lists before they are updated. From the user's side, `pacman` simply waits at startup without any message.
- Requests from the daemon itself and from `hm` and its subprocesses are always allowed through, to avoid deadlocks.
- A cooldown (default 60 s) prevents `hm` from running repeatedly. It also applies after a failed or timed-out run.
- **The daemon guarantees a check before the operation, not that the check succeeds.** If `hm` fails or times out, the waiting programs are still released and continue with the existing mirror lists. `hm` leaves the mirrorlists as they were when it fails (they keep the state of the last successful run), shows a desktop notification, and the daemon logs `hm FAILED (exit code N)` or `hm TIMED OUT` at error priority.
- On timeout (default 30 s) `hm` is killed together with its child processes. Children are found through their parent links, also when they moved to another session or process group; a process that detaches completely from `hm`'s process tree (double fork) is not tracked, which `hm` never does.
- If a watched file is replaced (editor, `sed -i`, package update), the daemon re-marks the new file immediately via an inotify watch on its directory. A slow periodic check (`RECHECK`) is kept as a safety net. If a watched path is a symlink, replacement of its target is found only by that periodic check (and not at all with `RECHECK=0`).
- On stop (`SIGTERM`/`SIGINT`) the daemon starts no new `hm` runs, lets a running `hm` finish for up to `STOP_GRACE` seconds, releases all held requests and exits. `hm` defers `SIGTERM`/`SIGINT`/`SIGHUP` while it replaces mirrorlists, so a stop cannot interrupt an update halfway.
- At most `MAX_HELD` requests are held while `hm` runs; further ones are let through, so a flood of local processes cannot exhaust the daemon's file descriptors. This trades strict enforcement for availability: requests beyond the limit may proceed with the previous mirror lists.
- Invalid configuration (see the table below) stops the daemon at startup with a message that names the variable. Unrecoverable `fanotify`/`inotify` errors do the same at runtime.
- Exit status: `0` after a requested stop, `1` for invalid configuration or an infrastructure error, `2` for an unexpected internal error (the traceback is in the journal). Before exiting after an error the daemon answers the requests it still holds; whatever is left, the kernel allows when the daemon's `fanotify` descriptor is closed, so `pacman` cannot hang because the daemon died. systemd restarts the service.
- A malfunction while classifying a single request (for example an unreadable `/proc` entry) is logged and that request is let through without triggering `hm`; the daemon keeps running.

### Configuration

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
| `HM` | `/usr/local/bin/hm` | Script to run (absolute path) |
| `HM_TIMEOUT` | `30` | Seconds before `hm` is killed (> 0) |
| `COOLDOWN` | `60` | Minimum seconds between `hm` runs (≥ 0) |
| `WATCH` | `/etc/pacman.conf` | Files to monitor (colon-separated, at least one) |
| `SHELLY_RE` | `shelly.*` | Process names that always trigger `hm` (regular expression) |
| `HELPERS_RE` | `yay\|paru\|pikaur\|trizen\|octopi` | AUR helpers and frontends that trigger `hm` when run bare or with a sync/upgrade operation (regular expression) |
| `RECHECK` | `600` | Safety-net check (seconds) that every watched file is still marked and the directory watches exist; `0` disables it (≥ 0). Replacements are normally detected immediately via inotify |
| `MAX_HELD` | `256` | Maximum number of `open()` calls held while `hm` runs; further ones are let through (integer ≥ 1) |
| `STOP_GRACE` | `5` | Seconds a running `hm` may finish when the service is stopped (≥ 0) |

Numbers must be finite; a value that does not match its constraint makes the service fail to start with a message such as `invalid MAX_HELD='0': must be an integer >= 1`.

### Security

The daemon runs as root and executes `/usr/local/bin/hm` as root. `hm` and its parent directories must be owned by root, must not be symlinks and must not be writable by group or others; `install-daemon.sh` checks this when installing.

The service is sandboxed with `ProtectSystem=strict`, `NoNewPrivileges`, `ProtectHome=read-only`, private `/tmp` and `/dev`, protected kernel interfaces and a restricted set of address families. It may write only to the directories of the managed mirrorlists (`hm` replaces files by rename, which needs directory access). Inside them, `hooks/` and `gnupg/` (pacman runs hooks as root; `gnupg` is the package keyring) and any `HookDir`/`GPGDir` reported by `pacman-conf` are read-only. The generated unit (`systemctl cat hm-daemon.service`) has a comment for every non-obvious setting.

Capabilities are limited to three, all verified to be necessary:

| Capability | Why |
|---|---|
| `CAP_SYS_ADMIN` | `fanotify_init` with permission events (without it: `fanotify_init: Operation not permitted`) |
| `CAP_SETUID`, `CAP_SETGID` | `hm` switches to the logged-in user with `setpriv` to show desktop notifications (without them `setpriv` fails) |

`Restart=always` keeps the guard running if it is killed; `StartLimitBurst=5` within 60 s turns a permanent startup error into a visible failed state.

Process names are not authenticated: any local process named `pacman` (or matching `SHELLY_RE`/`HELPERS_RE`) that opens `pacman.conf` with a sync operation can trigger `hm`, at most once per `COOLDOWN`. This gives no privileges, because `hm` takes no input from the triggering process, but it can delay other `pacman` runs for the duration of one `hm` run.

## Error notifications

When `hm` is not run in a terminal (for example by `hm-daemon`, or from a keybinding), errors are also shown as desktop notifications: failed downloads, unparsable API responses, failed `sudo` authentication and repositories without any active mirror. In a terminal the error is printed as usual and no notification is sent.

- When run as a regular user, `hm` calls `notify-send` directly.
- When run as root (by the daemon), `hm` notifies every active user session, using `setpriv` to switch to that user. Delivery results and failures are written to the journal (`journalctl -u hm-daemon.service`).
- Control: `HM_NOTIFY=auto|always|never` (default `auto`). Send a test notification with `hm --notify-test`.

## Diagnostics

To follow the daemon logs in real time:

```bash
journalctl -fu hm-daemon.service
```

Each `open()` is logged with the process name, command line and whether it triggered `hm` (`trigger=True/False`, `cooldown=True/False`), followed by `started`, the `hm` output, `hm finished OK` or `hm FAILED (exit code N)`, and `releasing ... (hm exited with code N)`.

Warnings and errors carry a journal priority, so problems can be listed directly:

```bash
journalctl -u hm-daemon.service -p warning   # hm failures, timeouts, hold limit, configuration and infrastructure errors
```

To see exactly what the service is allowed to do:

```bash
systemctl show hm-daemon.service -p ReadWritePaths -p ReadOnlyPaths -p CapabilityBoundingSet
systemd-analyze security hm-daemon.service
```

## Tests

`test-hm-daemon.sh` exercises `hm-daemon` against a scratch file in `/tmp`. It never touches `/etc/pacman.conf`, the installed service or the mirrorlists: it starts its own daemon instances (with `COOLDOWN=0`, `RECHECK=0` and a stub instead of `hm`) and uses a symlink named `pacman` to `cat` as a fake client.

```bash
./test-hm-daemon.sh                      # uses ./hm-daemon
./test-hm-daemon.sh /path/to/hm-daemon
```

The script re-runs itself with `sudo` (fanotify permission events need root). It needs `python3`, `awk`, `pkill`/`pgrep` (procps-ng), `setsid` and `timeout` (util-linux, coreutils), plus a kernel with fanotify permission events.

| # | What is checked |
|---|---|
| 1 | The mark follows a replaced file (`mv`, `sed -i`, `rm` + create, `ln -f`, in-place write): after each change a fake `pacman --sync` still triggers `hm` |
| 2 | `SIGTERM` while a request is held: the request is released after `STOP_GRACE`, the daemon exits with code 0 and the stub `hm` is killed |
| 3 | `SIGKILL` of the daemon while six requests are held: the kernel lets all of them through |
| 4 | `MAX_HELD`: with a limit of 5, exactly 5 of 12 concurrent requests are held, the rest pass |
| 5 | `hm` cannot be started: the request is not left blocked and the error is logged |
| 6 | `hm` exceeds `HM_TIMEOUT` and has a child in another session: both are killed and the request is released |
| 7 | Invalid configuration (`MAX_HELD=0`, `HM_TIMEOUT=nan`): the daemon exits with status 1 and names the variable |
| 8 | A symlinked watch path with `RECHECK=0` produces a warning that replacement will not be detected |

A successful run ends with `passed: 23, failed: 0` and exit status 0. Tests 1, 2 and 6 depend on timing (for example, in test 1 the new inode has to be re-marked before the fake client opens the file; a 0.2 s margin is used). If a single case fails on a heavily loaded system, run the script again before investigating.

The script does **not** cover `hm` itself (mirror evaluation, transactional updates), desktop notifications, the systemd sandbox or the installers. Check those with:

```bash
hm --notify-test                  # notification path of a regular user
sudo hm                           # real run; then: grep -c '^#UH#' /etc/pacman.d/*mirrorlist*
sudo hm --clean                   # removes the markers again
journalctl -fu hm-daemon.service  # watch the daemon, e.g. while running `pacman -Ss foo`
```

Installer rollback (installs a deliberately broken daemon and checks that the previous version returns):

```bash
{ head -n1 hm-daemon; echo 'raise SystemExit(3)'; tail -n +2 hm-daemon; } > /tmp/hm-daemon-broken
SRC=/tmp/hm-daemon-broken ./install-daemon.sh; echo "exit=$?"   # expected: update rolled back, exit=1
systemctl is-active hm-daemon.service                           # expected: active (previous version)
cmp hm-daemon /usr/local/bin/hm-daemon && echo "previous version restored"
rm -f /tmp/hm-daemon-broken
```

## Repository files

| File | Purpose |
|---|---|
| `hm` | The mirror health check |
| `hm-daemon` | The optional fanotify service that runs `hm` before `pacman`/`shelly` read the mirror lists |
| `install.sh` | Installs `hm` to `/usr/local/bin` |
| `install-daemon.sh` | Installs, updates (with rollback) or removes (`--remove`) the hardened `hm-daemon.service` |
| `test-hm-daemon.sh` | Tests for the daemon |
| `docs/` | Images used in this README |

## License

See [LICENSE](LICENSE).
