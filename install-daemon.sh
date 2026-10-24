#!/usr/bin/env bash
# install-daemon.sh - install / remove the hardened hm-daemon systemd service
#
# Installs the LOCAL hm-daemon file (next to this script, or SRC=/path/to/hm-daemon).
# This script never downloads anything.

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
    rm -f "$UNIT" "$BIN"
    systemctl daemon-reload
    ok removed "$SVC and $BIN"
    exit 0
fi

# ----------------------------------------------------------------------------- install
# 1) the daemon source (local file only)
[[ -f $SRC ]] || die "hm-daemon not found: $SRC
  Clone the repository ($REPOSITORY_URL) and run the script from there, or set SRC=/path/to/hm-daemon"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
[[ $(head -c 2 "$SRC") == '#!' ]] || die "$SRC has no shebang"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SRC" 2>/dev/null || die "$SRC is not valid Python"

# 2) hm runs as root: it must be a regular file reached through real (non-symlink)
#    path components, and it and every parent directory up to / must be owned by
#    root and not group/world-writable
[[ -e $HM ]] || die "$HM not found - install hm first"
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

# 3) install the daemon: root:root, 0755
systemctl disable --now -q "$SVC" 2>/dev/null || true
install -o root -g root -m 0755 "$SRC" "$BIN"

# 4) writable paths = directories of the (symlink-resolved) Include= files in pacman.conf.
#    Parsed the same way hm does it (lines starting with "Include").
RW_LIST=()
while IFS= read -r inc; do
    [[ -n $inc ]] || continue
    if [[ $inc =~ [[:space:]] ]]; then
        warn "skipping Include path containing whitespace: $inc"
        continue
    fi
    RW_LIST+=("$(dirname -- "$(readlink -f -- "$inc")")")
done < <(grep '^Include' /etc/pacman.conf \
            | sed -E 's/[[:space:]]+$//; s/^Include[[:space:]]*=[[:space:]]*//' | sort -u)
(( ${#RW_LIST[@]} > 0 )) || RW_LIST=(/etc/pacman.d)

mapfile -t RW_DIRS < <(printf '%s\n' "${RW_LIST[@]}" | sort -u)
RW=
for d in "${RW_DIRS[@]}"; do
    [[ -d $d ]] || warn "ReadWritePaths directory does not exist: $d"
    RW+="-$d "
done
RW="${RW% }"

# 5) generate the hardened service unit
rm -f "$UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Run hm before pacman/shelly read pacman.conf and mirrorlist
After=local-fs.target

[Service]
Type=simple
ExecStart=$BIN
Restart=always
RestartSec=1

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$RW
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SETUID CAP_SETGID
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
chown root:root "$UNIT"; chmod 0644 "$UNIT"

# 6) activate and verify
systemctl daemon-reload
systemctl enable --now -q "$SVC"
sleep 1
if ! systemctl is-active --quiet "$SVC"; then
    journalctl -u "$SVC" -n 15 --no-pager >&2 || true
    die "$SVC failed to start (log above)"
fi

EXPOSURE=$(systemd-analyze security "$SVC" --no-pager 2>/dev/null | tail -n1 | sed 's/.*: //')
SHOWN=$(IFS=,; echo "${RW_DIRS[*]}")
ok installed "$BIN (root:root 0755)"
ok service   "$SVC active, enabled at boot"
ok hardening "exposure ${EXPOSURE:-n/a}; writable: ${SHOWN//,/, }"
printf '\n%sLogs:%s   journalctl -fu %s\n%sRemove:%s %s --remove\n%sRepo:%s   %s\n' \
    "$D" "$N" "$SVC" "$D" "$N" "$SELF" "$D" "$N" "$REPOSITORY_URL"
