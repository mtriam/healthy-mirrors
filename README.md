# healthy-mirrors

Checks CachyOS mirror health and automatically marks out-of-sync or unhealthy mirrors in the mirrorlist, leaving only healthy mirrors active to help prevent partial upgrades and system breakage.

## What it does

The script fetches the current mirror health data from the CachyOS API, keeps only entries with `overall_status == "healthy"`, and updates `/etc/pacman.d/cachyos-mirrorlist` accordingly.

It also prints how many mirrors are active and how many remain commented out.

## Requirements

- `curl`
- `jq`
- `sed`
- `grep`
- `sudo`

## Install

```bash
mkdir -p ~/.local/bin
wget -O ~/.local/bin/hm https://raw.githubusercontent.com/mtriam/healthy-mirrors/refs/heads/main/hm
chmod +x ~/.local/bin/hm
```

## Use

```bash
hm
hm --clean
hm -c
```

`-c` / `--clean` restores the mirror list to its original state by removing only the `#UH#` marker prefix from previously flagged `Server = ...` lines, without deleting any active mirror entries.

## Alias

`up` refreshes the healthy mirror list, runs the system upgrade or package install, and finally restores the original mirrorlist state with `hm -c`.

zsh:

```bash
echo 'up() { ~/.local/bin/hm && sudo pacman -Syu "$@"; ~/.local/bin/hm -c; }' >> ~/.zshrc
source ~/.zshrc
```

fish:

```bash
echo 'function up; ~/.local/bin/hm; and sudo pacman -Syu $argv; or true; ~/.local/bin/hm -c; end' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```

Examples:

```bash
up
up firefox
```

## Optional: add to PATH

If you want to run `hm` directly without typing the full path, add `~/.local/bin` to your shell config.

zsh:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

fish:

```bash
echo 'set -gx PATH $HOME/.local/bin $PATH' >> ~/.config/fish/config.fish
source ~/.config/fish/config.fish
```
