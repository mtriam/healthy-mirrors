#!/usr/bin/env bash
# install-daemon.sh - install / remove the hardened hm-daemon systemd service
#
# Installs the LOCAL hm-daemon file (next to this script, or SRC=/path/to/hm-daemon).
# This script never downloads anything.
#
# Installing means trusting the file: it is installed as root and then runs as root.
# The script therefore refuses sources that others could have modified, copies the
# file into a root-only staging directory, validates that exact copy, installs that
# copy atomically and restores the previous version if the new one does not start.
set -eu

# Source repository (informational only)
REPOSITORY_URL="https://github.com/mtriam/healthy-mirrors"

SELF=$(readlink -f "$0")
LOCAL_SRC="${SELF%/*}/hm-daemon"
SRC="${SRC:-$LOCAL_SRC}"
BIN=/usr/local/bin/hm-daemon
UNIT=/etc/systemd/system/hm-daemon.service
SVC=hm-daemon.service
HM=/usr/local/bin/hm

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; Y=; D=; N=; fi
ok()   { printf '%s✔%s %-10s %s\n' "$G" "$N" "$1" "$2"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() {
    echo "Usage: ${SELF##*/} [--remove|--uninstall|-r] [-h]"
    echo "  (no option)  install/update $SVC from the local file \$SRC (default: ${LOCAL_SRC})"
    echo "  --remove     stop and remove the service and the binary"
    echo "Repository: $REPOSITORY_URL"
}

ACTION=install
case "${1:-}" in
    "")                        ;;
    -r|--remove|--uninstall)   ACTION=remove ;;
    -h|--help)                 usage; exit 0 ;;
    *)                         usage >&2; exit 1 ;;
esac

# self-elevate
[[ $EUID -eq 0 ]] || exec sudo env SRC="$SRC" NO_COLOR="${NO_COLOR:-}" "$SELF" "$@"

# ----------------------------------------------------------------------------- remove
if [[ $ACTION == remove ]]; then
    if [[ ! -e $UNIT && ! -e $BIN ]]; then echo "Nothing to remove ($SVC is not installed)."; exit 0; fi
    systemctl disable --now -q "$SVC" 2>/dev/null || true
    rm -f -- "$UNIT" "$BIN"
    systemctl daemon-reload
    ok removed "$SVC and $BIN"
    if [[ -d $UNIT.d ]]; then warn "drop-in directory left in place: $UNIT.d"; fi
    exit 0
fi

# ----------------------------------------------------------------------------- install
# a file that is installed as root must belong to root or to the user who ran sudo,
# and must not be writable by everybody (symlinks are followed: the real file counts)
check_origin() {
    local f=$1 owner perms
    owner=$(stat -L -c %u -- "$f") && perms=$(stat -L -c %A -- "$f") || die "cannot stat $f"
    if [[ $owner != 0 && $owner != "${SUDO_UID:-}" ]]; then
        die "$f is owned by uid $owner (expected root or the invoking user)"
    fi
    [[ ${perms:8:1} != w ]] || die "$f is world-writable ($perms)"
    [[ ${perms:5:1} != w ]] || warn "$f is group-writable ($perms)"
}

join_list() {
    local out='' x
    for x in "$@"; do out+="${out:+, }$x"; done
    printf '%s' "$out"
}

# 1) provenance of the installer and of the source
check_origin "$SELF"
[[ -f $SRC ]] || die "hm-daemon not found: $SRC
  Clone the repository ($REPOSITORY_URL) and run the script from there, or set SRC=/path/to/hm-daemon"
check_origin "$SRC"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# 2) staging: validate the exact bytes that will be installed
STAGE=$(mktemp -d /run/hm-install.XXXXXX) || die "cannot create a staging directory in /run"
cleanup() { rm -rf -- "$STAGE"; rm -f -- "$BIN.new" "$UNIT.new"; }
trap cleanup EXIT

install -m 0755 -- "$SRC" "$STAGE/hm-daemon" || die "cannot copy $SRC"
[[ $(head -c 2 "$STAGE/hm-daemon") == '#!' ]] || die "$SRC has no shebang"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$STAGE/hm-daemon" 2>/dev/null \
    || die "$SRC is not valid Python"

# 3) hm runs as root: it must be a regular file reached through real (non-symlink)
#    path components, and it and every parent directory up to / must be owned by
#    root and not group/world-writable
[[ -e $HM ]] || die "$HM not found - install hm first (install.sh)"
HM_REAL=$(readlink -f -- "$HM")
[[ $HM_REAL == "$HM" ]] || die "$HM is, or sits behind, a symlink (resolves to $HM_REAL)"
[[ -f $HM && -x $HM ]] || die "$HM is not an executable regular file"
p=$HM
while :; do
    [[ $(stat -c %u -- "$p") == 0 ]] || die "$p is not owned by root"
    perms=$(stat -c %A -- "$p")
    [[ ${perms:5:1} != w && ${perms:8:1} != w ]] || die "$p is group/world-writable ($perms)"
    [[ $p == / ]] && break
    p=$(dirname -- "$p")
done

# 4) writable directories: hm itself says which mirrorlists it updates (single source of truth).
#    hm replaces files by rename, which needs write access to their directories.
"$HM" --help 2>&1 | grep -q -- '--list' || die "installed hm is too old (no --list); run install.sh first"
LIST_OUT=$("$HM" --list) || die "hm --list failed"
mapfile -t LISTS <<<"$LIST_OUT"
(( ${#LISTS[@]} > 0 )) && [[ -n ${LISTS[0]} ]] || die "hm reports no mirrorlists"

RW_LIST=()
for f in "${LISTS[@]}"; do
    [[ $f =~ [[:space:]] ]] && die "mirrorlist path contains whitespace (not supported in ReadWritePaths): $f"
    if [[ -L $f ]]; then warn "$f is a symlink; hm cannot update symlinked mirrorlists"; fi
    RW_LIST+=("$(dirname -- "$f")")
done
mapfile -t RW_DIRS < <(printf '%s\n' "${RW_LIST[@]}" | sort -u)
RW=
for d in "${RW_DIRS[@]}"; do
    case $d in
        /|/etc|/usr|/var|/boot|/root|/home|/opt|/srv)
            die "refusing to make $d writable for the service (mirrorlists belong in a dedicated directory)" ;;
    esac
    [[ -d $d ]] || die "mirrorlist directory does not exist: $d"
    RW+="-$d "
done
RW="${RW% }"

# 5) read-only subdirectories inside the writable ones: pacman runs hooks as root and
#    gnupg holds the package keyring, so a compromised service must not be able to write there
RO_CAND=()
if command -v pacman-conf >/dev/null 2>&1; then
    while IFS= read -r x; do
        if [[ -n $x && $x != / ]]; then RO_CAND+=("${x%/}"); fi
    done < <({ pacman-conf HookDir; pacman-conf GPGDir; } 2>/dev/null || true)
fi
for d in "${RW_DIRS[@]}"; do RO_CAND+=("$d/hooks" "$d/gnupg"); done

declare -A SEEN_RO=()
RO_DIRS=()
for c in "${RO_CAND[@]}"; do
    [[ -n $c && -d $c && ! -L $c && ! $c =~ [[:space:]] ]] || continue
    [[ -z ${SEEN_RO[$c]:-} ]] || continue
    inside=0
    for r in "${RW_DIRS[@]}"; do
        if [[ $c == "$r" || $r == "$c"/* ]]; then inside=0; break; fi   # would hide a writable directory
        if [[ $c == "$r"/* ]]; then inside=1; fi
    done
    if (( inside )); then SEEN_RO[$c]=1; RO_DIRS+=("$c"); fi
done
RO_BLOCK=
if (( ${#RO_DIRS[@]} > 0 )); then
    RO=
    for c in "${RO_DIRS[@]}"; do RO+="-$c "; done
    RO_BLOCK="# Sensitive subdirectories inside the writable ones (verified: the nested read-only entry wins)
ReadOnlyPaths=${RO% }"
fi

# 6) the hardened unit (staged first; nothing on the system has changed so far)
cat > "$STAGE/hm-daemon.service" <<EOF
[Unit]
Description=Run hm before pacman/shelly read pacman.conf and mirrorlist
After=local-fs.target
# A permanent startup error ends in a visible failed state instead of an endless restart loop
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$BIN
# Keep the guard running even if it is killed or exits cleanly outside of systemd
Restart=always
RestartSec=1

# --- Hardening ---------------------------------------------------------------
NoNewPrivileges=yes
ProtectSystem=strict
# Directories of the mirrorlists hm updates (it replaces files by rename)
ReadWritePaths=$RW
$RO_BLOCK
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
MemoryDenyWriteExecute=yes
ProcSubset=pid
UMask=0077
# CAP_SYS_ADMIN: fanotify_init with permission events (verified: without it the daemon
#   stops with "fanotify_init: Operation not permitted")
# CAP_SETUID, CAP_SETGID: hm switches to the logged-in user (setpriv) to show desktop
#   notifications (verified: without them setpriv fails with "Operation not permitted")
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SETUID CAP_SETGID
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

# advisory check of the staged unit (ExecStart points at the staged copy for this check only)
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -- "$STAGE/verify"
    sed "s|^ExecStart=.*|ExecStart=$STAGE/hm-daemon|" "$STAGE/hm-daemon.service" > "$STAGE/verify/hm-daemon.service"
    if ! VERIFY=$(systemd-analyze verify "$STAGE/verify/hm-daemon.service" 2>&1); then
        warn "systemd-analyze verify reported problems (continuing; the start check below decides):"
        printf '%s\n' "$VERIFY" >&2
    fi
fi

# 7) remember the current state, so that a failed update can be rolled back
HAD_BIN=0; HAD_UNIT=0; WAS_ACTIVE=0; WAS_ENABLED=0
if [[ -e $BIN ]]; then HAD_BIN=1; cp -a -- "$BIN" "$STAGE/prev.bin"; fi
if [[ -e $UNIT ]]; then HAD_UNIT=1; cp -a -- "$UNIT" "$STAGE/prev.unit"; fi
if systemctl is-active --quiet "$SVC"; then WAS_ACTIVE=1; fi
if systemctl is-enabled --quiet "$SVC" 2>/dev/null; then WAS_ENABLED=1; fi

# 8) swap and activate. Every step is checked explicitly: inside a function that is
#    tested by "if", set -e is not in effect.
commit_update() {
    systemctl stop "$SVC" 2>/dev/null || true
    install -o root -g root -m 0755 -- "$STAGE/hm-daemon" "$BIN.new" || return 1
    mv -f -- "$BIN.new" "$BIN" || return 1
    install -o root -g root -m 0644 -- "$STAGE/hm-daemon.service" "$UNIT.new" || return 1
    mv -f -- "$UNIT.new" "$UNIT" || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now -q "$SVC" || return 1
    sleep 2
    local restarts
    restarts=$(systemctl show -p NRestarts --value "$SVC" 2>/dev/null || true)
    if ! systemctl is-active --quiet "$SVC" || [[ ${restarts:-0} != 0 ]]; then
        journalctl -u "$SVC" -n 15 --no-pager >&2 || true
        return 1
    fi
    # what is on disk must be exactly what was validated
    [[ $(stat -c '%u:%g:%a' -- "$BIN") == 0:0:755 ]] && cmp -s -- "$STAGE/hm-daemon" "$BIN" || return 1
    [[ $(stat -c '%u:%g:%a' -- "$UNIT") == 0:0:644 ]] && cmp -s -- "$STAGE/hm-daemon.service" "$UNIT" || return 1
    return 0
}

rollback() {
    warn "update failed; restoring the previous version"
    systemctl stop "$SVC" 2>/dev/null || true
    if (( HAD_BIN )); then
        { cp -a -- "$STAGE/prev.bin" "$BIN.new" && mv -f -- "$BIN.new" "$BIN"; } || warn "could not restore $BIN"
    else
        rm -f -- "$BIN"
    fi
    if (( HAD_UNIT )); then
        { cp -a -- "$STAGE/prev.unit" "$UNIT.new" && mv -f -- "$UNIT.new" "$UNIT"; } || warn "could not restore $UNIT"
    else
        systemctl disable -q "$SVC" 2>/dev/null || true
        rm -f -- "$UNIT"
    fi
    systemctl daemon-reload || true
    if (( HAD_UNIT )); then
        if (( ! WAS_ENABLED )); then systemctl disable -q "$SVC" 2>/dev/null || true; fi
        if (( WAS_ACTIVE )); then
            systemctl start "$SVC" 2>/dev/null || warn "the previous version did not start either"
        fi
    fi
    return 0
}

if ! commit_update; then
    rollback
    die "$SVC update failed and was rolled back (see messages above)"
fi

# 9) summary
EXPOSURE=$(systemd-analyze security "$SVC" --no-pager 2>/dev/null | tail -n1 | sed 's/.*: //')
HARDENING="exposure ${EXPOSURE:-n/a}; writable: $(join_list "${RW_DIRS[@]}")"
if (( ${#RO_DIRS[@]} > 0 )); then HARDENING+="; read-only inside: $(join_list "${RO_DIRS[@]}")"; fi
ok installed "$BIN (root:root 0755)"
ok service   "$SVC active, enabled at boot"
ok hardening "$HARDENING"
printf '\n%sLogs:%s   journalctl -fu %s\n%sRemove:%s %s --remove\n%sRepo:%s   %s\n' \
    "$D" "$N" "$SVC" "$D" "$N" "$SELF" "$D" "$N" "$REPOSITORY_URL"
