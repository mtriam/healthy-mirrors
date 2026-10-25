#!/usr/bin/env bash
# install.sh - install hm to /usr/local/bin
#
# Installs the LOCAL hm file (next to this script, or SRC=/path/to/hm).
# This script never downloads anything.
#
# Installing means trusting the file: it is installed as root and later run as root
# (by hm-daemon). The script refuses sources that others could have modified, copies
# the file into a root-only staging directory, validates that exact copy and installs
# it atomically.
set -euo pipefail

# Source repository (informational only)
REPOSITORY_URL="https://github.com/mtriam/healthy-mirrors"

SELF=$(readlink -f -- "$0")
SRC="${SRC:-${SELF%/*}/hm}"
INSTALL_PATH=/usr/local/bin/hm

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; Y=; D=; N=; fi
ok()   { printf '%s✔%s %-10s %s\n' "$G" "$N" "$1" "$2"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() {
    echo "Usage: ${SELF##*/} [-h]"
    echo "  Installs the local hm file (default: ${SELF%/*}/hm, override with SRC=/path/to/hm) to $INSTALL_PATH"
    echo "Repository: $REPOSITORY_URL"
}

case "${1:-}" in
    "")        ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; exit 1 ;;
esac

# self-elevate
[[ $EUID -eq 0 ]] || exec sudo env SRC="$SRC" NO_COLOR="${NO_COLOR:-}" "$SELF" "$@"

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

# 1) provenance of the installer and of the source
check_origin "$SELF"
[[ -f $SRC ]] || die "hm not found: $SRC
  Clone the repository ($REPOSITORY_URL) and run the script from there, or set SRC=/path/to/hm"
check_origin "$SRC"

# 2) staging: validate the exact bytes that will be installed
STAGE=$(mktemp -d /run/hm-install.XXXXXX) || die "cannot create a staging directory in /run"
cleanup() { rm -rf -- "$STAGE"; rm -f -- "$INSTALL_PATH.new"; }
trap cleanup EXIT

install -m 0755 -- "$SRC" "$STAGE/hm" || die "cannot copy $SRC"
[[ $(head -c 2 "$STAGE/hm") == '#!' ]] || die "$SRC has no shebang"
bash -n "$STAGE/hm" 2>/dev/null || die "$SRC has a bash syntax error"

# 3) destination
DEST_DIR=${INSTALL_PATH%/*}
[[ ! -L $DEST_DIR ]] || die "$DEST_DIR is a symlink; refusing to install"
perms=$(stat -c %A -- "$DEST_DIR" 2>/dev/null || true)
if [[ -n $perms ]]; then
    [[ $(stat -c %u -- "$DEST_DIR") == 0 ]] || die "$DEST_DIR is not owned by root"
    [[ ${perms:5:1} != w && ${perms:8:1} != w ]] || die "$DEST_DIR is group/world-writable ($perms)"
fi

# 4) atomic install (hm-daemon may run hm at any moment)
install -D -o root -g root -m 0755 -- "$STAGE/hm" "$INSTALL_PATH.new" || die "cannot write $INSTALL_PATH.new"
mv -f -- "$INSTALL_PATH.new" "$INSTALL_PATH" || die "cannot replace $INSTALL_PATH"

# 5) verify what was installed
[[ $(stat -c '%u:%g:%a' -- "$INSTALL_PATH") == 0:0:755 ]] || die "unexpected owner or mode on $INSTALL_PATH"
cmp -s -- "$STAGE/hm" "$INSTALL_PATH" || die "$INSTALL_PATH differs from the validated copy"

missing=()
for cmd in curl jq awk sed grep cmp mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then warn "missing required tools: ${missing[*]}"; fi
command -v notify-send >/dev/null 2>&1 || warn "notify-send not found (optional: desktop notifications on errors)"

ok source    "$SRC"
ok installed "$INSTALL_PATH (root:root 0755)"
printf '\n%sNext:%s   %s/install-daemon.sh   (optional: run hm automatically before pacman/shelly)\n%sRepo:%s   %s\n' \
    "$D" "$N" "${SELF%/*}" "$D" "$N" "$REPOSITORY_URL"
