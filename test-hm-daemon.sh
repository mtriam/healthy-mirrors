#!/usr/bin/env bash
# test-hm-daemon.sh - exercise hm-daemon against a scratch file in /tmp (never touches /etc/pacman.conf)
# usage: ./test-hm-daemon.sh [path/to/hm-daemon]
set -u
SELF=$(readlink -f "$0")
[[ $EUID -eq 0 ]] || exec sudo "$SELF" "$@"

D=$(readlink -f "${1:-${SELF%/*}/hm-daemon}")
[[ -f $D ]] || { echo "hm-daemon not found: $D" >&2; exit 1; }
T=$(mktemp -d /tmp/hmtest.XXXXXX)
CONF=$T/pacman.conf
LOG=$T/log
DPID=
PASS=0
FAIL=0

cleanup() {
    [[ -n $DPID ]] && kill -KILL "$DPID" 2>/dev/null
    pkill -f '^sleep 20$' 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo '[options]' > "$CONF"
ln -s /usr/bin/cat "$T/pacman"                         # a process named "pacman"
printf '#!/bin/sh\nexec sleep "${SLOW:-0.3}"\n' > "$T/slow-hm"
chmod +x "$T/slow-hm"

pac()     { "$T/pacman" -- --sync "$CONF" >/dev/null 2>&1; }   # looks like "pacman --sync", opens the file
started() { grep -c '^started ' "$LOG"; }
secs()    { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }

start_daemon() {          # extra NAME=value arguments are passed to the daemon's environment
    env WATCH="$CONF" HM="$T/slow-hm" COOLDOWN=0 RECHECK=0 "$@" python3 -u "$D" > "$LOG" 2>&1 &
    DPID=$!
    sleep 0.5
}
stop_daemon() {
    [[ -n $DPID ]] || return 0
    kill -TERM "$DPID" 2>/dev/null
    wait "$DPID" 2>/dev/null
    DPID=
}

echo "== 1. mark follows a replaced file (no waiting for a periodic check)"
start_daemon
replace_test() {          # $1 = label, rest = command that replaces/changes the file
    local label=$1 before after
    shift
    before=$(started)
    "$@"
    sleep 0.2
    pac
    sleep 0.8
    after=$(started)
    [[ $after -gt $before ]] && ok "$label" || bad "$label (hm was not started)"
}
replace_test "rename over file (mv)"  bash -c 'cp "$0" "$0.new" && mv "$0.new" "$0"' "$CONF"
replace_test "sed -i"                 bash -c 'sed -i "s/^\[options\]/[options]/" "$0"' "$CONF"
replace_test "rm + create"            bash -c 'rm "$0" && echo "[options]" > "$0"' "$CONF"
replace_test "ln -f (hard link)"      bash -c 'echo "[options]" > "$0.other" && ln -f "$0.other" "$0"' "$CONF"
replace_test "in-place write"         bash -c 'echo "# x" >> "$0"' "$CONF"
grep -qE 'Traceback|^fatal:' "$LOG" && bad "daemon logged an error (see below)" && cat "$LOG"
stop_daemon

echo "== 2. SIGTERM while a request is held (hm still running)"
start_daemon SLOW=20 STOP_GRACE=2
pac & PP=$!
sleep 1
kill -0 "$PP" 2>/dev/null && ok "request is held while hm runs" || bad "request was not held"
T0=$(date +%s.%N)
kill -TERM "$DPID"
wait "$PP" 2>/dev/null
E=$(secs "$T0")
between "$E" 1.5 4.5 && ok "held request released after the grace period (${E}s)" \
                      || bad "held request released after ${E}s (expected about 2s)"
wait "$DPID" 2>/dev/null; RC=$?; DPID=
[[ $RC -eq 0 ]] && ok "daemon exited with code 0" || bad "daemon exit code $RC"
grep -q 'stop requested' "$LOG" && grep -q 'releasing 1 held' "$LOG" && ok "stop logged" || bad "stop not logged"
pgrep -f '^sleep 20$' >/dev/null && bad "hm child still running" || ok "hm child killed"

echo "== 3. SIGKILL of the daemon while a request is held (kernel behaviour)"
start_daemon SLOW=20
pac & PP=$!
sleep 1
kill -KILL "$DPID"
wait "$DPID" 2>/dev/null; DPID=
for _ in $(seq 20); do kill -0 "$PP" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PP" 2>/dev/null && bad "request still blocked 2 s after the daemon died" \
                          || ok "kernel released the held request"
pkill -f '^sleep 20$' 2>/dev/null

echo "== 4. hold limit"
start_daemon SLOW=2 MAX_HELD=5
pids=()
for _ in $(seq 12); do pac & pids+=($!); done
wait "${pids[@]}" 2>/dev/null
grep -q 'hold limit (5) reached' "$LOG" && ok "limit reached and logged" || bad "limit not logged"
grep -q 'releasing 5 held' "$LOG" && ok "exactly 5 requests were held" || bad "unexpected number of held requests"
stop_daemon

echo "== 5. hm cannot be started"
start_daemon HM=/nonexistent
timeout 3 "$T/pacman" -- --sync "$CONF" >/dev/null 2>&1
[[ $? -ne 124 ]] && ok "request was not left blocked" || bad "request stayed blocked"
grep -q 'cannot start' "$LOG" && ok "start failure logged" || bad "start failure not logged"
stop_daemon

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
