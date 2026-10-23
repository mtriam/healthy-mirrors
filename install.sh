#!/bin/bash
set -euo pipefail

REPOSITORY_URL="https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/hm"
INSTALL_PATH="/usr/local/bin/hm"
DOWNLOAD=$(mktemp)
trap 'rm -f "$DOWNLOAD"' EXIT

curl -fsSL "$REPOSITORY_URL" -o "$DOWNLOAD"

if [[ "$EUID" -eq 0 ]]; then
    install -m 755 "$DOWNLOAD" "$INSTALL_PATH"
else
    sudo -v
    sudo install -m 755 "$DOWNLOAD" "$INSTALL_PATH"
fi

printf 'Installed hm to %s\n' "$INSTALL_PATH"
