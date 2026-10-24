#!/usr/bin/env bash
# install-hm.sh - install hm from a local file only
#
# Installs the LOCAL hm file next to this script.
# This script never downloads anything.

set -eu

# Source repository (informational only)
REPOSITORY_URL="https://github.com/mtriam/healthy-mirrors"

INSTALL_PATH="/usr/local/bin/hm"

SELF=$(readlink -f -- "$0")
INSTALLER_DIR="${SELF%/*}"
LOCAL_HM="$INSTALLER_DIR/hm"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else
    G=; R=; Y=; D=; N=
fi

ok()   { printf '%s✔%s %-10s %s\n' "$G" "$N" "$1" "$2"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
    printf 'Usage: %s [-h]\n' "${SELF##*/}"
    printf '  Install/update hm from the local file: %s\n' "$LOCAL_HM"
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
esac

# Self-elevate
if [[ $EUID -ne 0 ]]; then
    exec sudo env NO_COLOR="${NO_COLOR:-}" "$SELF" "$@"
fi

# Validate the local source
[[ -f $LOCAL_HM ]] || die "hm not found: $LOCAL_HM
  Place the hm file next to this installer.
  Repository: $REPOSITORY_URL"

[[ $(head -c 2 "$LOCAL_HM") == '#!' ]] || die "$LOCAL_HM has no shebang"
[[ -r $LOCAL_HM ]] || die "$LOCAL_HM is not readable"

# Install
install -o root -g root -m 0755 "$LOCAL_HM" "$INSTALL_PATH"

ok installed "$INSTALL_PATH (root:root 0755)"
printf '\n%sRepo:%s %s\n' "$D" "$N" "$REPOSITORY_URL"
