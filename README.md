# healthy-mirrors

Checks mirror health and automatically keeps only healthy mirrors active, helping avoid partial upgrades and broken system states.

## What it does

The script reads the mirror lists included from `/etc/pacman.conf`, checks the current CachyOS mirror status, and keeps only mirrors that are fully synced for the relevant architecture. It also includes healthy Arch mirrors from the Arch Linux mirror status API when applicable.

It then updates the mirrorlist files by commenting out unhealthy mirrors while leaving healthy ones active, and prints a summary of active vs. disabled mirrors.

## Requirements

- `curl`
- `jq`
- `sed`
- `grep`
- `sudo` (only when mirrorlist files actually need updating)

## Install

Install system-wide to `/usr/local/bin`:

```bash
curl -fsSL https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/install.sh | bash
```

The installer asks for `sudo` only to install the file. The manual equivalent is:

```bash
tmp=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/hm -o "$tmp"
sudo install -m 755 "$tmp" /usr/local/bin/hm
rm -f "$tmp"
```

## Uninstall

```bash
sudo rm /usr/local/bin/hm
```

## Use

Run:

```bash
hm
hm --clean
hm -c
```

`-c` / `--clean` restores the mirror list to its original state by removing only the `#UH#` marker prefix from previously flagged `Server = ...` lines, without deleting any active mirrors. Both modes compare the generated result with the current file first, so an unchanged run does not ask for `sudo`.

## Alias

`up` refreshes the healthy mirror list, runs the system upgrade or package install, and finally restores the original mirrorlist state with `hm -c`.

zsh:

```bash
echo 'up() { hm && sudo pacman -Syu "$@"; hm -c; }' >> ~/.zshrc
source ~/.zshrc
```

fish:

```bash
echo 'function up; hm; and sudo pacman -Syu $argv; or true; hm -c; end' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Examples:

```bash
up           # safely upgrade the system
up firefox   # safely install Firefox
```
