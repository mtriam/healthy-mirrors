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
- `sudo`

## Install

```bash
mkdir -p ~/.local/bin
wget -O ~/.local/bin/hm https://raw.githubusercontent.com/mtriam/healthy-mirrors/refs/heads/main/hm
chmod +x ~/.local/bin/hm
```

## Use

If installed to `~/.local/bin`, run:

```bash
~/.local/bin/hm
~/.local/bin/hm --clean
~/.local/bin/hm -c
```

If you added `~/.local/bin` to `PATH`, you can use:

```bash
hm
hm --clean
hm -c
```

`-c` / `--clean` restores the mirror list to its original state by removing only the `#UH#` marker prefix from previously flagged `Server = ...` lines, without deleting any active mirrors.

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
up           # safely upgrade the system
up firefox   # safely install Firefox
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
