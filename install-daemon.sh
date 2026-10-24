#!/usr/bin/env bash
# install-daemon.sh - install / remove the hardened hm-daemon systemd service
set -eu

SELF=$(readlink -f "$0")
REPOSITORY_URL="https://raw.githubusercontent.com/mtriam/healthy-mirrors/main/hm-daemon"
LOCAL_SRC="${SELF%/*}/hm-daemon"
if [[ ${SRC_WAS_SET+x} != x ]]; then
    SRC_WAS_SET=${SRC+x}
fi
SRC="${SRC:-$LOCAL_SRC}"
BIN=/usr/local/bin/hm-daemon
UNIT=/etc/systemd/system/hm-daemon.service
SVC=hm-daemon.service
HM=/usr/local/bin/hm

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else G=; R=; D=; N=; fi
ok()  { printf '%s✔%s %-10s %s\n' "$G" "$N" "$1" "$2"; }
die() { printf '%s✘%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
usage() { echo "Usage: ${SELF##*/} [--remove|--uninstall|-r] [-h]"; echo "  (no option)  install/update $SVC from \$SRC (default: ./hm-daemon)"; echo "  --remove     stop and remove the service and the binary"; }

ACTION=install
case "${1:-}" in
    "")                        ;;
    -r|--remove|--uninstall)   ACTION=remove ;;
    -h|--help)                 usage; exit 0 ;;
    *)                         usage >&2; exit 1 ;;
esac

# self-elevate
[[ $EUID -eq 0 ]] || exec sudo env SRC="$SRC" SRC_WAS_SET="$SRC_WAS_SET" \
    NO_COLOR="${NO_COLOR:-}" "$SELF" "$@"

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
DOWNLOAD=
if [[ ! -f $SRC ]]; then
    if [[ -n $SRC_WAS_SET ]]; then
        die "source not found: $SRC"
    fi
    DOWNLOAD=$(mktemp)
    trap 'rm -f "$DOWNLOAD"' EXIT
    curl -fsSL "$REPOSITORY_URL" -o "$DOWNLOAD"
    SRC=$DOWNLOAD
    printf 'Downloaded hm-daemon from %s\n' "$REPOSITORY_URL"
fi
head -c 2 "$SRC" | grep -q '^#!' || die "$SRC has no shebang"
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SRC" 2>/dev/null || die "$SRC is not valid Python"

# hm runs as root: it and its path must be root-owned and not group/world-writable
[[ -x $HM ]] || die "$HM missing or not executable"
for p in "$HM" /usr/local/bin /usr/local /usr; do
    owner=$(stat -c %u "$p"); mode=$(stat -c %a "$p")
    if [[ $owner != 0 ]] || (( 0${mode: -2:1} & 2 )) || (( 0${mode: -1} & 2 )); then
        die "$p is not root-owned or is group/world-writable (owner=$owner mode=$mode)"
    fi
done

systemctl disable --now -q "$SVC" 2>/dev/null || true
install -o root -g root -m 0755 "$SRC" "$BIN"

# writable paths = directories of all Include= entries in pacman.conf
RW=$(grep -E '^[[:space:]]*Include' /etc/pacman.conf \
      | sed -E 's/^[[:space:]]*Include[[:space:]]*=[[:space:]]*//; s/[[:space:]]+$//' \
      | xargs -r -n1 dirname | sort -u | sed 's/^/-/' | tr '\n' ' ')
RW="${RW:--/etc/pacman.d}"

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

systemctl daemon-reload
systemctl enable --now -q "$SVC"
sleep 1
if ! systemctl is-active --quiet "$SVC"; then
    journalctl -u "$SVC" -n 15 --no-pager >&2 || true
    die "$SVC failed to start (log above)"
fi

EXPOSURE=$(systemd-analyze security "$SVC" --no-pager 2>/dev/null | tail -n1 | sed 's/.*: //')
ok installed "$BIN (root:root 0755)"
ok service   "$SVC active, enabled at boot"
ok hardening "exposure ${EXPOSURE:-n/a}; writable: ${RW#-}" 
printf '\n%sLogs:%s   journalctl -fu %s\n%sRemove:%s %s --remove\n' "$D" "$N" "$SVC" "$D" "$N" "$SELF"
