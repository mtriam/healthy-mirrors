#!/bin/bash
set -euo pipefail

REPOSITORY_URL="https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/hm"
INSTALL_PATH="/usr/local/bin/hm"

INSTALLER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LOCAL_HM="$INSTALLER_DIR/hm"

if [[ -f "$LOCAL_HM" ]]; then
    SOURCE_PATH="$LOCAL_HM"
    printf 'Using local hm from %s\n' "$LOCAL_HM"
else
    DOWNLOAD=$(mktemp)
    trap 'rm -f "$DOWNLOAD"' EXIT
    SOURCE_PATH="$DOWNLOAD"
    curl -fsSL "$REPOSITORY_URL" -o "$DOWNLOAD"
fi

install_hm() {
    if [[ "$EUID" -eq 0 ]]; then
        install -m 755 "$SOURCE_PATH" "$INSTALL_PATH"
    else
        sudo -v
        sudo install -m 755 "$SOURCE_PATH" "$INSTALL_PATH"
    fi
}

install_hm

printf 'Installed hm to %s\n' "$INSTALL_PATH"

