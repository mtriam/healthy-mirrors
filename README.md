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

See [Usage](#usage) for manual operation, [hm-daemon](#hm-daemon) for details and configuration, [Blocking mode](#blocking-mode-deny_on) for making sure nothing runs with outdated lists, and [Limitations](#limitations) for what `hm` deliberately does not do.

## What it does

The `hm` script reads existing mirror-list files included via `/etc/pacman.conf` (including ordinary shell-glob patterns) and checks the current CachyOS and Arch Linux mirror status using their respective APIs. Non-absolute or missing `Include` entries are skipped; if no existing mirror-list file is found, the script fails. A mirror-list file that is a symlink is an error (see [Limitations](#limitations)).

For CachyOS, it checks mirror synchronization separately for the `x86_64`, `x86_64_v3`, and `x86_64_v4` architectures. A mirror is considered healthy for a given architecture only if all reported checks for that architecture are synchronized.

For Arch Linux mirrors, it keeps only active HTTPS mirrors that are fully synchronized (`completion_pct = 1.0`), have a reported synchronization time, and have a delay of less than one hour.

The script updates the mirrorlist files by commenting out unhealthy mirrors with a `#UH#` marker while leaving healthy mirrors active. It removes existing markers before re-evaluating the mirrors, so the status is refreshed on each run. Use `hm --clean` to remove the markers.

Only mirrors that the APIs know are ever disabled: a mirror is commented out when the API lists it and reports it as unhealthy. Mirrors the APIs do not list at all (a local cache, your own server, a company mirror, ...) are left exactly as they are and count as active in the summary. For example, on CachyOS the `cachyos-rate-mirrors` tool typically puts `https://archlinux.cachyos.org/repo/$repo/os/$arch` at the top of `/etc/pacman.d/mirrorlist`; the Arch mirror status API does not list it, so `hm` keeps it and the Arch list is summarized as `, 1 other`. `hm` cannot judge such mirrors: if one of them is unreachable from your location, remove it from the list yourself. Side effect: a mirror that has been removed from the API, or a variant of a mirror (for example `http://`) that the API does not list, also stays active.

**Every list is judged on its own.** A list that cannot be updated safely is left exactly as it is, and the other lists are updated as usual. A list is skipped when it would end up without an active mirror, or when it contains mirrors the API knows but none of them is healthy (unmanaged mirrors alone are no replacement for the official ones; this usually means that the API data for that list is wrong or incomplete). `hm` reports the skipped lists in one warning and, outside a terminal, in one desktop notification:

```text
==== mirror summary (on/off): cachyos-v4 (21/7, skipped) | cachyos (20/8) | arch (29/7, 1 other) ====
WARNING: left unchanged: cachyos-v4: none of the mirrors listed by the API is healthy (no active mirror would be left)
```

A skipped list is shown with the state it currently has (marked `skipped`). The exit status tells the outcome apart (see [Exit status](#exit-status)): if only some lists are skipped, `hm` exits with status `2`; if no list could be updated, with status `1`.

API responses and mirror URLs are validated, and API data is never interpreted as `sed` or regex syntax. Entries of an API response that cannot be used are skipped with a warning (`ignored N of M malformed entries`); a response in which more than half of the entries are malformed is refused.

Updates are transactional: every changed file is first staged and backed up next to the original (`.hm-stage.*`, `.hm-backup.*` in the mirrorlist directory), checked against an invariant (the only difference may be the `#UH#` marker in front of `Server = ` lines), and then replaced with `mv`. If any step fails, files already replaced are restored from their backups, so a failed run leaves the mirrorlists as they were. `SIGTERM`, `SIGINT` and `SIGHUP` received during an update are deferred until it has finished. Each individual file is replaced atomically, but a set of files cannot be replaced as one atomic operation (see [Limitations](#limitations)). If `hm` is killed with `SIGKILL` in the middle of an update (for example by the daemon timeout), leftover `.hm-stage.*` / `.hm-backup.*` files may remain. `hm` removes `.hm-stage.*` files older than one day (as root on every run, as a regular user whenever it writes anyway); `.hm-backup.*` files are never removed automatically, because after a failed rollback a backup may be the only intact copy. A successfully restored file consumes its backup, so only backups of files that could not be restored are kept, and they are reported.

After processing the mirror lists, it prints a summary showing the number of active and disabled mirrors for each list (`on/off`); when mirrors unknown to the APIs were left untouched, their number is added as `, N other` (they are included in `on`), and a list that was left unchanged is marked `, skipped`.

### Exit status

| Status | Meaning |
|---|---|
| `0` | All lists were processed: healthy mirrors are active, unhealthy ones are disabled. |
| `1` | An error occurred, or no list could be updated. Nothing was changed. |
| `2` | Some lists were skipped (left exactly as they were, possibly out of date), the others were updated. |

Status `2` also applies to `--dry-run`, so that a preview agrees with a real run. A caller that must not continue with lists that are not up to date (the `up` function below, [hm-daemon in blocking mode](#blocking-mode-deny_on)) should treat everything other than `0` as "not safe".

## Limitations

- **Symlinked mirrorlists are not supported.** `hm` stops with an error. Updating a symlink would write through it, outside of the transaction (copying a symlink over the staging file with `cp -a` turns the staging file itself into a symlink).
- **`Include` paths containing whitespace are not supported.** They are split into words and not recognized. The installer refuses them as well.
- **A skipped list keeps its previous state.** That state may contain `#UH#` markers from an earlier run, which can be out of date until the API data for that list is healthy again.
- **A set of files is not replaced atomically.** Every file is replaced atomically (and each one is valid on its own), but a program that reads the mirrorlists while `hm` runs may briefly see some lists updated and others not. When `hm` is started by `hm-daemon`, such programs are held until it finishes. After a crash or power loss, every file is either the old or the new version, and leftover `.hm-stage.*` / `.hm-backup.*` files may remain.
- **No locking between runs.** Two `hm` runs at the same time (for example a manual `hm` while the daemon runs one) are not serialized. The result is one of the valid states, possibly built from two different API snapshots; the next run corrects it.
- **Unmanaged mirrors are never judged** (see above), and a failed run keeps the lists as they were: they may be out of date, never half-written.
- **Abbreviated long options** of `pacman` (such as `--syn`) are not recognized by `hm-daemon`.
- **Blocking mode is a guard, not a security boundary.** See [Blocking mode](#blocking-mode-deny_on): it can be bypassed on purpose (retry within the cooldown), and it does not apply to requests beyond `MAX_HELD`, to programs that are not recognized as clients, or while the daemon is not running.

## Requirements

All dependencies are already satisfied on a default CachyOS installation.

`hm`:

- `bash`, `curl`, `jq`, `sed`, `grep`, `awk`, `cmp`, `find`, `mktemp`, `mv`, `cp`, `timeout`
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
- asks `hm --list` which mirrorlists exist, so that `hm` and the service sandbox agree on the writable directories (`hm --list` stops with an error when a mirrorlist is a symlink),
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
- Settings made with a systemd drop-in (`/etc/systemd/system/hm-daemon.service.d/`), including those made with `--configure`, are kept.
- **Behavior change in this version:** `hm` now exits with status `2` (instead of `0`) when it skipped some lists. With the default daemon settings nothing changes for you (the daemon lets programs continue, see below); the `up` function below no longer starts the upgrade in that case.

## Uninstall

Remove the markers first, otherwise commented-out mirrors stay disabled:

```bash
hm --clean
./install-daemon.sh --remove   # if the daemon is installed
sudo rm /usr/local/bin/hm
```

`--remove` stops and removes `hm-daemon.service` and `/usr/local/bin/hm-daemon`. Drop-ins (made with `--configure` or `systemctl edit`) are left in `/etc/systemd/system/hm-daemon.service.d/`, so your settings survive a later install; remove the directory manually if needed.

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
| `-n`, `--dry-run` | Show what would change (which mirrors would be disabled or enabled, which lists would be skipped, which stale staging files removed, which mirrors are left as they are because the APIs do not know them) and the resulting summary, but write nothing and do not ask for `sudo`. Works together with `--clean` |
| `--list` | Print the mirrorlist files `hm` manages (the existing files from the `Include` lines of `pacman.conf`) and exit, without network access or writes. Fails if a mirrorlist is a symlink |
| `--notify-test` | Send a test desktop notification and exit |
| `-h`, `--help` | Show the help message |

`--list` and `--notify-test` cannot be combined with other options; `--dry-run` can be combined with `--clean`. Set `HM_NOTIFY=auto|always|never` to control desktop notifications on errors (default `auto`, see [Error notifications](#error-notifications); notifications are always off with `--dry-run` and `--list`).

Both `hm` and `hm --clean` compare the generated result with the current file before writing changes, so an unchanged run does not ask for `sudo`.

Example of a dry run:

```text
$ hm --dry-run
==== dry run: nothing is written ====
hm: would update /etc/pacman.d/cachyos-mirrorlist
    disable  https://mirror.example.org/cachyos/repo/$arch/$repo
hm: left as it is (not known to the API): /etc/pacman.d/mirrorlist: https://archlinux.cachyos.org/repo/$repo/os/$arch
==== mirror summary (on/off): cachyos-v4 (3/1) | cachyos (3/1) | arch (3/0, 1 other) ====
```

Exit status: `0`, `1` or `2`, see [Exit status](#exit-status).

### Shell function: `up`

The `up` function refreshes the healthy mirror list with `hm` and then runs a system upgrade, optionally installing the given packages. **The upgrade is started only if `hm` exits with status `0`**: on an error (`1`), when no list could be updated (`1`) and when some lists were skipped (`2`) it is not. In the last case you have seen `hm`'s warning; if you accept the lists that were left as they were, run `sudo pacman -Syu` directly.

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

#### Variant: continue when some lists were skipped

If you prefer the previous behavior (only an error or a complete failure stops the upgrade; lists that `hm` skipped keep the state they had before), accept status `2` as well:

```zsh
up() { hm || [ $? -eq 2 ] && sudo pacman -Syu "$@"; }
```

```fish
function up; hm; or test $status -eq 2; and sudo pacman -Syu $argv; end
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
- A cooldown (default 60 s) prevents `hm` from running repeatedly. It also applies after a failed, partial or timed-out run. It is measured from the end of the run.
- All intervals (cooldown, `hm` timeout, stop grace period, periodic check) use the monotonic clock, so a change of the system time (NTP correction after boot, resume from suspend) cannot shorten or extend them.
- **By default the daemon guarantees a check before the operation, not that the check succeeds.** If `hm` fails, skips lists or times out, the waiting programs are still released and continue with the existing mirror lists. `hm` leaves the mirrorlists as they were when it fails (they keep the state of the last successful run) and shows a desktop notification. To change this, use the [blocking mode](#blocking-mode-deny_on).
- The daemon logs the outcome by `hm`'s exit status:
  - `0`: `hm finished OK`,
  - `2` (some lists skipped, the others updated): `hm skipped some mirror lists (exit code 2)` at warning priority. This is not logged as a failure,
  - anything else: `hm FAILED (exit code N)` or `hm timed out` at error priority.
- On timeout (default 30 s) `hm` is killed together with its child processes. Children are found through their parent links, also when they moved to another session or process group; a process that detaches completely from `hm`'s process tree (double fork) is not tracked, which `hm` never does.
- If a watched file is replaced (editor, `sed -i`, package update), the daemon re-marks the new file immediately via an inotify watch on its directory. A slow periodic check (`RECHECK`) is kept as a safety net. If a watched path is a symlink, replacement of its target is found only by that periodic check (and not at all with `RECHECK=0`).
- On stop (`SIGTERM`/`SIGINT`) the daemon starts no new `hm` runs, lets a running `hm` finish for up to `STOP_GRACE` seconds, releases all held requests (never denies them) and exits. `hm` defers `SIGTERM`/`SIGINT`/`SIGHUP` while it replaces mirrorlists, so a stop cannot interrupt an update halfway.
- At most `MAX_HELD` requests are held while `hm` runs; further ones are let through, so a flood of local processes cannot exhaust the daemon's file descriptors. This trades strict enforcement for availability: requests beyond the limit may proceed with the previous mirror lists.
- Invalid configuration (see the table below) stops the daemon at startup with a message that names the variable. Unrecoverable `fanotify`/`inotify` errors do the same at runtime.
- Exit status: `0` after a requested stop, `1` for invalid configuration or an infrastructure error, `2` for an unexpected internal error (the traceback is in the journal). Before exiting after an error the daemon answers the requests it still holds; whatever is left, the kernel allows when the daemon's `fanotify` descriptor is closed, so `pacman` cannot hang because the daemon died. systemd restarts the service.
- A malfunction while classifying a single request (for example an unreadable `/proc` entry) is logged and that request is let through without triggering `hm`; the daemon keeps running.

### Blocking mode (`DENY_ON`)

By default nothing is ever blocked for good: after `hm` the held programs always continue, even if the lists could not be brought up to date. `DENY_ON` changes that for people who want **only upgrades on up-to-date lists** to run. It has three levels:

| `DENY_ON` | `hm` exit `0` | `hm` exit `2` (some lists skipped) | `hm` exit `1`, timeout, `hm` cannot be started |
|---|---|---|---|
| `off` (default) | continue | continue | continue |
| `failure` | continue | continue | **blocked** |
| `partial` | continue | **blocked** | **blocked** |

`failure` blocks only when the check as a whole failed (no list could be updated, API unreachable, ...). `partial` is the strict level: a single skipped list is enough to block. Enable it with `./install-daemon.sh --configure` or with a systemd drop-in:

```bash
sudo systemctl edit hm-daemon.service
```

```ini
[Service]
Environment="DENY_ON=partial"
```

What "blocked" means: the daemon answers the waiting `open()` of `/etc/pacman.conf` with `FAN_DENY`, so it fails with `EPERM` and the program stops before it reads any mirror list. `pacman` reports something like `error: could not open file /etc/pacman.conf: Operation not permitted`. That message alone does not say why, so the reason is shown elsewhere (see below).

**Retry within the cooldown.** After a blocked run the cooldown starts. A program started again within `COOLDOWN` seconds (default 60) is **let through, without a new `hm` run**: it continues with the existing, not fully updated lists. This is the deliberate way to say "I know, upgrade anyway". After the cooldown expires the next start runs `hm` again, which may succeed in the meantime. With `COOLDOWN=0` there is no such window: a blocked program stays blocked until a check succeeds (the daemon warns about this combination at startup).

**Who is blocked.** Only processes that would trigger `hm` themselves (`pacman -Syu`, `yay`, `shelly`, ... see [What triggers `hm`](#what-triggers-hm)). Any other process that happens to open the file while `hm` runs (an editor, `cat`, `pacman -Q`) is held for the duration of the run like before, but is always allowed afterwards.

**How you are told.**

- Desktop notification (when `hm` is not run in a terminal, see [Error notifications](#error-notifications)): the daemon tells `hm` that blocking is on, so `hm`'s notification and its journal output add: *Programs waiting for this check were blocked (DENY_ON=...). Starting the program again within N s lets it continue with the existing mirror lists.*
- Journal (`journalctl -u hm-daemon.service`): `hm FAILED (exit code N)` or `hm skipped some mirror lists (exit code 2)`, followed by `denying X of Y held open() calls (DENY_ON=..., pid ...): they fail with EPERM; starting the program again within N s lets it continue with the existing mirror lists`.

**What is never blocked.**

- Stopping or restarting the daemon (`SIGTERM`, the end of `STOP_GRACE`) releases everything. A stop is not a failure of `hm`.
- Requests beyond `MAX_HELD` are let through (availability over strictness).
- If the daemon dies, the kernel allows all outstanding requests.
- Programs that are not recognized as clients, and the operations that do not trigger `hm` (`pacman -Q`, ...).
- A program that already has `pacman.conf` open or has read the lists before the daemon started: the guard only sees `open()` calls.

Known limitations of blocking mode:

- On a **timeout** `hm` is killed and cannot send a desktop notification; the denial then shows up only as `EPERM` in the program and in the journal.
- The blocked program has no way to learn from the failed `open()` how long to wait; look at the notification or the journal.
- Process names are not authenticated (see [Security](#security)): this protects against forgetting, not against a local user who wants to bypass it.

### Configuration

The easy way is the interactive setup, which explains every option, offers the current value as the default and validates your answers with the same rules as the daemon:

```bash
./install-daemon.sh --configure
```

For each option it shows a colored description (with a table of values for `DENY_ON`) and an overview and summary table. It asks for `DENY_ON`, `COOLDOWN`, `HM_TIMEOUT`, `HELPERS_RE`, `SHELLY_RE`, `WATCH`, `MAX_HELD`, `STOP_GRACE` and `RECHECK` (press Enter to keep the value in brackets, type `default` to restore the built-in default), shows a summary and applies it only after you confirm. The answers are written to `/etc/systemd/system/hm-daemon.service.d/hm-config.conf` (only the values that differ from the defaults; if none do, the file is removed), then the service is restarted. **If the service does not start with the new settings, the previous settings are restored.** You can run it again at any time; the current values are read back from that file. `HM` (the path of the script) is not offered, because the installer verifies that path and generates the sandbox for it. The service must be installed first, and a terminal is required.

Settings made by hand with `systemctl edit` (`override.conf`) sort after `hm-config.conf` and win over it; `--configure` warns if such a file sets the same options.

To set variables by hand instead, use a systemd drop-in:

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
| `COOLDOWN` | `60` | Minimum seconds between `hm` runs (≥ 0). In blocking mode also the window in which a blocked program can be started again |
| `WATCH` | `/etc/pacman.conf` | Files to monitor (colon-separated, at least one) |
| `SHELLY_RE` | `shelly.*` | Process names that always trigger `hm` (regular expression) |
| `HELPERS_RE` | `yay\|paru\|pikaur\|trizen\|octopi` | AUR helpers and frontends that trigger `hm` when run bare or with a sync/upgrade operation (regular expression) |
| `RECHECK` | `600` | Safety-net check (seconds) that every watched file is still marked and the directory watches exist; `0` disables it (≥ 0). Replacements are normally detected immediately via inotify |
| `MAX_HELD` | `256` | Maximum number of `open()` calls held while `hm` runs; further ones are let through (integer ≥ 1) |
| `STOP_GRACE` | `5` | Seconds a running `hm` may finish when the service is stopped (≥ 0) |
| `DENY_ON` | `off` | `off`, `failure` or `partial`: when to block the programs that triggered a `hm` run, see [Blocking mode](#blocking-mode-deny_on) |

Numbers must be finite; a value that does not match its constraint makes the service fail to start with a message such as `invalid MAX_HELD='0': must be an integer >= 1`. An unknown `DENY_ON` value is rejected the same way (`invalid DENY_ON='abc': must be one of off, failure, partial`).

### Security

The daemon runs as root and executes `/usr/local/bin/hm` as root. `hm` and its parent directories must be owned by root, must not be symlinks and must not be writable by group or others; `install-daemon.sh` checks this when installing.

The service is sandboxed with `ProtectSystem=strict`, `NoNewPrivileges`, `ProtectHome=read-only`, private `/tmp` and `/dev`, protected kernel interfaces, no writable-and-executable memory (`MemoryDenyWriteExecute`), a `/proc` that shows only process directories (`ProcSubset=pid`) and a restricted set of address families. It may write only to the directories of the managed mirrorlists (`hm` replaces files by rename, which needs directory access). Inside them, `hooks/` and `gnupg/` (pacman runs hooks as root; `gnupg` is the package keyring) and any `HookDir`/`GPGDir` reported by `pacman-conf` are read-only. The generated unit (`systemctl cat hm-daemon.service`) has a comment for every non-obvious setting.

Capabilities are limited to three, all verified to be necessary:

| Capability | Why |
|---|---|
| `CAP_SYS_ADMIN` | `fanotify_init` with permission events (without it: `fanotify_init: Operation not permitted`) |
| `CAP_SETUID`, `CAP_SETGID` | `hm` switches to the logged-in user with `setpriv` to show desktop notifications (without them `setpriv` fails) |

Blocking mode needs no additional capability or unit change: `FAN_DENY` is an answer to the same permission events the daemon already receives.

`Restart=always` keeps the guard running if it is killed; `StartLimitBurst=5` within 60 s turns a permanent startup error into a visible failed state.

Process names are not authenticated: any local process named `pacman` (or matching `SHELLY_RE`/`HELPERS_RE`) that opens `pacman.conf` with a sync operation can trigger `hm`, at most once per `COOLDOWN`. This gives no privileges, because `hm` takes no input from the triggering process, but it can delay other `pacman` runs for the duration of one `hm` run. In blocking mode such a process can additionally make a *failed* run deny other triggering programs that are held at that moment, and a process named like a non-client is never denied. This is a convenience guard, not an access control mechanism.

## Error notifications

When `hm` is not run in a terminal (for example by `hm-daemon`, or from a keybinding), errors are also shown as desktop notifications: failed downloads, unparsable or broken API responses, failed `sudo` authentication, symlinked mirrorlists, and lists that were left unchanged (one notification names all of them, see [What it does](#what-it-does)). In a terminal the error is printed as usual and no notification is sent.

- When run as a regular user, `hm` calls `notify-send` directly.
- When run as root (by the daemon), `hm` notifies every active user session, using `setpriv` to switch to that user. Delivery results and failures are written to the journal (`journalctl -u hm-daemon.service`).
- When the daemon runs in [blocking mode](#blocking-mode-deny_on) and the outcome blocks programs, the notification and the journal output also say so, and for how many seconds a retry gets through.
- Control: `HM_NOTIFY=auto|always|never` (default `auto`). Notifications are always off with `--dry-run` and `--list`. Send a test notification with `hm --notify-test`.

## Diagnostics

To follow the daemon logs in real time:

```bash
journalctl -fu hm-daemon.service
```

Each `open()` is logged with the process name and whether it triggered `hm` (`trigger=True/False`, `cooldown=True/False`). The command line is logged only for `pacman`, AUR helpers and `shelly`; any other process that opens the file is logged by name only and its command line is not even read. A triggering open is followed by `started`, the `hm` output, `hm finished OK`, `hm skipped some mirror lists (exit code 2)` or `hm FAILED (exit code N)`, and `releasing ... (hm exited with code N)`. In blocking mode a line `denying X of Y held open() calls ...` follows when requests were denied.

Warnings and errors carry a journal priority, so problems can be listed directly:

```bash
journalctl -u hm-daemon.service -p warning   # hm failures, skipped lists, denials, timeouts, hold limit, configuration and infrastructure errors
```

To see exactly what the service is allowed to do:

```bash
systemctl show hm-daemon.service -p ReadWritePaths -p ReadOnlyPaths -p CapabilityBoundingSet
systemd-analyze security hm-daemon.service
```

## Tests

`test-hm-daemon.sh` exercises `hm-daemon` against a scratch file in `/tmp`. It never touches `/etc/pacman.conf`, the installed service or the mirrorlists: it starts its own daemon instances (with `COOLDOWN=0`, `RECHECK=0` and a stub instead of `hm`) and uses a symlink named `pacman` to `cat` as a fake client. Test 9 imports `hm-daemon` as a module (nothing is started) to check how command lines are classified.

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
| 7 | Invalid configuration (`MAX_HELD=0`, `HM_TIMEOUT=nan`, `DENY_ON=abc`): the daemon exits with status 1 and names the variable |
| 8 | A symlinked watch path with `RECHECK=0` produces a warning that replacement will not be detected |
| 9 | Classification of 30 command lines: short and long `pacman` options (including `-F -y`, `--files -y`, `-b/path`), AUR helpers, `shelly`, other programs |
| 10 | The log names every process that opens the file, but shows command lines only for `pacman`, AUR helpers and `shelly` |
| 11 | Cooldown: a fresh daemon starts `hm` for the first request, a second request within the cooldown does not start it again |
| 12 | `hm` exits with an error: the request is released and the failure is logged at error priority |
| 13 | `hm` exits with `2` and `DENY_ON` is off: the request is released, logged as a warning and not as a failure |
| 14 | `DENY_ON=failure`: exit `2` is let through, a failure is denied (`EPERM`) and logged |
| 15 | `DENY_ON=partial`: both exit `2` and a failure are denied |
| 16 | Only triggering processes are denied: a `cat` that was held during the same run is allowed and reads the file (`denying 1 of 2`) |
| 17 | A retry within the cooldown goes through, and `hm` is not started again |
| 18 | `hm` timeout and `hm` that cannot be started are denied too (`DENY_ON=failure`) |
| 19 | Stopping the daemon with a held request never denies it |
| 20 | `hm` receives `HM_DENY_ON` and `HM_DENY_RETRY` in deny mode, and neither otherwise (also not inherited from the daemon's environment) |
| 21 | `DENY_ON` together with `COOLDOWN=0` produces a warning at startup |

A successful run ends with `passed: 50, failed: 0` and exit status 0. Tests 1, 2 and 6 depend on timing (for example, in test 1 the new inode has to be re-marked before the fake client opens the file; a 0.2 s margin is used), as do tests 16 and 19. If a single case fails on a heavily loaded system, run the script again before investigating.

The script does **not** cover `hm` itself (mirror evaluation, transactional updates, exit status `0`/`1`/`2`), desktop notifications, the systemd sandbox or the installers (including `--configure`). Check those with:

```bash
hm --dry-run; echo "exit=$?"     # what a run would change, nothing is written; 0, 1 or 2
hm --notify-test                  # notification path of a regular user
sudo hm; echo "exit=$?"           # real run; then: grep -c '^#UH#' /etc/pacman.d/*mirrorlist*
sudo hm --clean                   # removes the markers again
journalctl -fu hm-daemon.service  # watch the daemon, e.g. while running `pacman -Ss foo`
```

To try the blocking mode by hand, set `DENY_ON=partial` in a drop-in, make `hm` fail (for example by going offline), run `pacman -Sy` and watch the `denying ...` line in the journal; run it again within `COOLDOWN` seconds to see it pass.

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
| `install-daemon.sh` | Installs, updates (with rollback), configures interactively (`--configure`) or removes (`--remove`) the hardened `hm-daemon.service` |
| `test-hm-daemon.sh` | Tests for the daemon |
| `docs/` | Images used in this README |

## License

See [LICENSE](LICENSE).
