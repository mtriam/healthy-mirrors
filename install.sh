#!/usr/bin/env bash
# install.sh - install hm, hm-daemon, hm-setup and the service unit to /usr/local/bin
#              and /etc/systemd/system (for installs from a git checkout; Arch users
#              can use the PKGBUILD instead)
#
# Installs the LOCAL files (next to this script, or SRC_DIR=/path/to/checkout).
# This script never downloads anything.
#
# Installing means trusting the files: they are installed as root and later run as root
# (by hm-daemon). The script refuses sources that others could have modified, copies the
# files into a root-only staging directory, validates those exact copies and installs
# them atomically. The daemon is configured and started with hm-setup.
set -euo pipefail

# Source repository (informational only)
REPOSITORY_URL="https://github.com/mtriam/healthy-mirrors"

SELF=$(readlink -f -- "$0")
SRC_DIR="${SRC_DIR:-${SELF%/*}}"
BIN_DIR=/usr/local/bin
SVC=hm-daemon.service
UNIT=/etc/systemd/system/$SVC
SCRIPTS=(hm hm-daemon hm-setup)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; Y=; D=; N=; fi
ok()   { printf '%s✔%s %-10s %s\n' "$G" "$N" "$1" "$2"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() {
    echo "Usage: ${SELF##*/} [--uninstall] [-h]"
    echo "  (no option)  install/update ${SCRIPTS[*]} in $BIN_DIR and $SVC in /etc/systemd/system"
    echo "               from the local checkout (default: ${SELF%/*}, override with SRC_DIR=/path)"
    echo "  --uninstall  stop the service, remove the #UH# markers and remove all installed files"
    echo "Then run 'hm-setup' to configure and start the daemon."
    echo "Repository: $REPOSITORY_URL"
}

ACTION=install
case "${1:-}" in
    "")                      ;;
    -u|--uninstall|--remove) ACTION=uninstall ;;
    -h|--help)               usage; exit 0 ;;
    *)                       usage >&2; exit 1 ;;
esac

# self-elevate
[[ $EUID -eq 0 ]] || exec sudo env SRC_DIR="$SRC_DIR" NO_COLOR="${NO_COLOR:-}" "$SELF" "$@"

# ----------------------------------------------------------------------------- uninstall
if [[ $ACTION == uninstall ]]; then
    if [[ -x $BIN_DIR/hm-setup ]]; then
        "$BIN_DIR/hm-setup" --remove || warn "hm-setup --remove failed"
    else
        systemctl disable --now -q "$SVC" 2>/dev/null || true
    fi
    # otherwise the commented-out mirrors would stay disabled
    if [[ -x $BIN_DIR/hm ]]; then
        "$BIN_DIR/hm" --clean || warn "could not remove the #UH# markers; run 'hm --clean' by hand"
    fi
    for f in "${SCRIPTS[@]}"; do rm -f -- "$BIN_DIR/$f"; done
    rm -f -- "$UNIT"
    systemctl daemon-reload 2>/dev/null || true
    ok removed "${SCRIPTS[*]} and $UNIT"
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

# 1) provenance of the installer and of the sources
check_origin "$SELF"
for f in "${SCRIPTS[@]}" hm-daemon.service; do
    [[ -f $SRC_DIR/$f ]] || die "$f not found in $SRC_DIR
  Clone the repository ($REPOSITORY_URL) and run the script from there, or set SRC_DIR=/path/to/checkout"
    check_origin "$SRC_DIR/$f"
done
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# 2) staging: validate the exact bytes that will be installed
STAGE=$(mktemp -d /run/hm-install.XXXXXX) || die "cannot create a staging directory in /run"
cleanup() {
    rm -rf -- "$STAGE"
    for f in "${SCRIPTS[@]}"; do rm -f -- "$BIN_DIR/$f.new"; done
    rm -f -- "$UNIT.new"
}
trap cleanup EXIT

for f in "${SCRIPTS[@]}"; do
    install -m 0755 -- "$SRC_DIR/$f" "$STAGE/$f" || die "cannot copy $SRC_DIR/$f"
    [[ $(head -c 2 "$STAGE/$f") == '#!' ]] || die "$SRC_DIR/$f has no shebang"
done
bash -n "$STAGE/hm" 2>/dev/null || die "hm has a bash syntax error"
bash -n "$STAGE/hm-setup" 2>/dev/null || die "hm-setup has a bash syntax error"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$STAGE/hm-daemon" 2>/dev/null \
    || die "hm-daemon is not valid Python"
# the unit in the repository points to /usr/bin (package layout)
sed "s|/usr/bin/|$BIN_DIR/|g" "$SRC_DIR/hm-daemon.service" > "$STAGE/hm-daemon.service" \
    || die "cannot prepare the unit"

# 3) destination
[[ ! -L $BIN_DIR ]] || die "$BIN_DIR is a symlink; refusing to install"
if [[ -d $BIN_DIR ]]; then
    perms=$(stat -c %A -- "$BIN_DIR")
    [[ $(stat -c %u -- "$BIN_DIR") == 0 ]] || die "$BIN_DIR is not owned by root"
    [[ ${perms:5:1} != w && ${perms:8:1} != w ]] || die "$BIN_DIR is group/world-writable ($perms)"
fi

# 4) atomic install (hm-daemon may run hm at any moment); hm first
for f in "${SCRIPTS[@]}"; do
    install -D -o root -g root -m 0755 -- "$STAGE/$f" "$BIN_DIR/$f.new" || die "cannot write $BIN_DIR/$f.new"
    mv -f -- "$BIN_DIR/$f.new" "$BIN_DIR/$f" || die "cannot replace $BIN_DIR/$f"
done
install -D -o root -g root -m 0644 -- "$STAGE/hm-daemon.service" "$UNIT.new" || die "cannot write $UNIT.new"
mv -f -- "$UNIT.new" "$UNIT" || die "cannot replace $UNIT"
systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed"

# 5) verify what was installed
for f in "${SCRIPTS[@]}"; do
    [[ $(stat -c '%u:%g:%a' -- "$BIN_DIR/$f") == 0:0:755 ]] || die "unexpected owner or mode on $BIN_DIR/$f"
    cmp -s -- "$STAGE/$f" "$BIN_DIR/$f" || die "$BIN_DIR/$f differs from the validated copy"
done
[[ $(stat -c '%u:%g:%a' -- "$UNIT") == 0:0:644 ]] && cmp -s -- "$STAGE/hm-daemon.service" "$UNIT" \
    || die "$UNIT differs from the validated copy"

missing=()
for cmd in curl jq awk sed grep cmp find mktemp mv cp timeout; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then warn "missing required tools: ${missing[*]}"; fi
command -v notify-send >/dev/null 2>&1 || warn "notify-send not found (optional: desktop notifications on errors)"

ok installed "${SCRIPTS[*]} in $BIN_DIR (root:root 0755)"
ok unit      "$UNIT"

# 6) an update of a running daemon: regenerate the sandbox paths and restart it
if systemctl is-active --quiet "$SVC" 2>/dev/null; then
    "$BIN_DIR/hm-setup" --refresh || warn "hm-setup --refresh failed; run it by hand"
else
    printf '\n%sNext:%s   run %shm-setup%s to configure and start the daemon (optional: runs hm\n         automatically before pacman/shelly)\n' \
        "$D" "$N" "$G" "$N"
fi
printf '%sRepo:%s   %s\n' "$D" "$N" "$REPOSITORY_URL"
