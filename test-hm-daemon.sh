#!/usr/bin/env bash
# test-hm-daemon.sh - exercise hm-daemon against a scratch file in /tmp (never touches /etc/pacman.conf)
# usage: ./test-hm-daemon.sh [path/to/hm-daemon]
set -u
SELF=$(readlink -f "$0")
[[ $EUID -eq 0 ]] || exec sudo "$SELF" "$@"
export LC_ALL=C                                        # the tests must not depend on the user's language

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
    pkill -f '^sleep (20|22|23)$' 2>/dev/null
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
# like pac, but succeeds only if the open() of the file was denied: cat then prints nothing of
# the file on stdout (the error message is language dependent, so it is not looked at)
denied()  { local out; out=$(timeout 10 "$T/pacman" -- --sync "$CONF" 2>/dev/null); [[ $out != *"[options]"* ]]; }
started() { grep -c '^started ' "$LOG"; }
secs()    { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; }
alive()   { local n=0 p; for p in "$@"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }

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
grep -qE 'Traceback|^(<[0-7]>)?fatal:' "$LOG" && bad "daemon logged an error (see below)" && cat "$LOG"
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

echo "== 3. SIGKILL of the daemon while several requests are held (kernel behaviour)"
start_daemon SLOW=20
pids=()
for _ in $(seq 6); do pac & pids+=($!); done
sleep 1
n=$(alive "${pids[@]}")
[[ $n -eq 6 ]] && ok "all 6 requests are held while hm runs" || bad "only $n of 6 requests are held"
kill -KILL "$DPID"
wait "$DPID" 2>/dev/null; DPID=
for _ in $(seq 20); do [[ $(alive "${pids[@]}") -eq 0 ]] && break; sleep 0.1; done
n=$(alive "${pids[@]}")
[[ $n -eq 0 ]] && ok "kernel released all held requests" || bad "$n requests still blocked 2 s after the daemon died"
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

echo "== 6. hm timeout kills hm and a child that left its process group"
printf '#!/bin/sh\nsetsid sleep 23 &\nexec sleep 22\n' > "$T/tree-hm"
chmod +x "$T/tree-hm"
start_daemon HM="$T/tree-hm" HM_TIMEOUT=2
T0=$(date +%s.%N)
pac & PP=$!
sleep 1
pgrep -f '^sleep 23$' >/dev/null && ok "child runs in its own session" || bad "child did not start (test setup)"
wait "$PP" 2>/dev/null
E=$(secs "$T0")
between "$E" 1.5 4.5 && ok "request released after the hm timeout (${E}s)" \
                      || bad "request released after ${E}s (expected about 2s)"
pgrep -f '^sleep 23$' >/dev/null && bad "child in another session survived" || ok "child in another session killed"
pgrep -f '^sleep 22$' >/dev/null && bad "hm survived the timeout" || ok "hm killed"
stop_daemon

echo "== 7. invalid configuration is rejected at startup"
check_rejected() {        # $1 = NAME=value
    local out rc
    out=$(timeout 5 env WATCH="$CONF" HM="$T/slow-hm" "$1" python3 -u "$D" 2>&1)
    rc=$?
    if [[ $rc -eq 1 && $out == *"${1%%=*}"* ]]; then
        ok "$1 rejected (exit 1, message names the variable)"
    else
        bad "$1 not rejected as expected (exit $rc): $out"
    fi
}
check_rejected MAX_HELD=0
check_rejected HM_TIMEOUT=nan
check_rejected DENY_ON=abc

echo "== 8. symlinked watch path with the periodic check disabled"
ln -s "$CONF" "$T/link.conf"
start_daemon WATCH="$T/link.conf"
grep -q 'will not be detected' "$LOG" && ok "symlink warning says that replacement will not be detected" \
                                       || bad "symlink warning missing or wrong"
stop_daemon

echo "== 9. classification of command lines (hm-daemon is imported, nothing is started)"
out=$(python3 - "$D" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("hmd", sys.argv[1])
spec = importlib.util.spec_from_loader("hmd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.load_config()

cases = [
    ("pacman", ["pacman", "-Syu"], True),
    ("pacman", ["pacman", "--sync", "--refresh", "--sysupgrade"], True),
    ("pacman", ["pacman", "--sync", "--noconfirm", "--", "pkg"], True),
    ("pacman", ["pacman", "--upgrade", "--noconfirm", "--", "/tmp/a.pkg.tar.zst"], True),
    ("pacman", ["pacman", "-U", "/tmp/a.pkg.tar.zst"], True),
    ("pacman", ["pacman", "-Ss", "foo"], True),
    ("pacman", ["pacman", "--files", "--refresh"], True),
    ("pacman", ["pacman", "--files", "-y"], True),
    ("pacman", ["pacman", "-F", "--refresh"], True),
    ("pacman", ["pacman", "-F", "-y"], True),
    ("pacman", ["pacman", "-Fy"], True),
    ("pacman", ["pacman", "-F", "foo"], False),
    ("pacman", ["pacman", "--files", "foo"], False),
    ("pacman", ["pacman", "-Qs", "S"], False),
    ("pacman", ["pacman", "--query", "--search", "x"], False),
    ("pacman", ["pacman", "-Qtdq"], False),
    ("pacman", ["pacman", "--database", "--asdeps", "--", "dbus-glib"], False),
    ("pacman", ["pacman", "-T", "dbus"], False),
    ("pacman", ["pacman", "--sysupgrade"], False),
    ("pacman", ["pacman", "-b/var/lib/US", "-Q"], False),
    ("pacman", ["pacman", "-Rns", "foo"], False),
    ("yay",    ["yay"], True),
    ("yay",    ["yay", "firefox"], True),
    ("yay",    ["yay", "-Qua"], False),
    ("yay",    ["yay", "--sync", "--sysupgrade"], True),
    ("paru",   ["paru", "-Sua"], True),
    ("octopi", ["octopi"], True),
    ("octopi-notifier", ["octopi-notifier"], False),
    ("shelly", ["shelly", "sync", "--force"], True),
    ("cat",    ["cat", "-S"], False),
]
bad = 0
for comm, argv, want in cases:
    got = m.should_trigger(comm, argv)
    if got != want:
        bad += 1
        print(f"  {comm}: {' '.join(argv[1:])} -> {got}, expected {want}")
print(f"{len(cases) - bad}/{len(cases)} classification cases OK")
sys.exit(1 if bad else 0)
PY
)
rc=$?
if [[ $rc -eq 0 ]]; then ok "$out"; else bad "classification: $out"; fi

echo "== 10. the log names every process but shows command lines only for clients"
start_daemon
cat "$CONF" >/dev/null
sleep 0.3
pac
sleep 0.8
if grep -q 'comm=cat trigger=False' "$LOG" && ! grep -q 'comm=cat .*cmd=' "$LOG"; then
    ok "another process is logged by name only"
else
    bad "log of a non-client process is missing or contains its command line"
fi
grep -q 'comm=pacman cmd=' "$LOG" && ok "pacman is logged with its command line" \
                                   || bad "pacman command line missing in the log"
stop_daemon

echo "== 11. cooldown: the first request starts hm, a second one within the cooldown does not"
start_daemon COOLDOWN=30
pac
sleep 0.5
pac
sleep 0.5
n=$(started)
[[ $n -eq 1 ]] && ok "hm was started exactly once (fresh daemon is not in cooldown)" \
               || bad "hm was started $n times (expected 1)"
grep -q 'trigger=True cooldown=True' "$LOG" && ok "second request logged as cooldown=True" \
                                            || bad "cooldown not logged for the second request"
stop_daemon

echo "== 12. hm fails: the request is released and the failure is logged at error priority"
printf '#!/bin/sh\nexit 3\n' > "$T/fail-hm"
chmod +x "$T/fail-hm"
start_daemon HM="$T/fail-hm"
timeout 5 "$T/pacman" -- --sync "$CONF" >/dev/null 2>&1
[[ $? -ne 124 ]] && ok "request was released after a failed hm" || bad "request stayed blocked"
grep -qF '<3>hm FAILED (exit code 3)' "$LOG" && ok "failure logged with error priority" \
                                              || bad "failure not logged as expected"
stop_daemon

# hm stubs for the DENY_ON tests
printf '#!/bin/sh\nexit 2\n' > "$T/partial-hm"                 # some lists skipped
printf '#!/bin/sh\nsleep 1\nexit 3\n' > "$T/slowfail-hm"        # fails after a second
printf '#!/bin/sh\necho "${HM_DENY_ON-unset} ${HM_DENY_RETRY-unset}" > "$OUT"\n' > "$T/env-hm"
chmod +x "$T/partial-hm" "$T/slowfail-hm" "$T/env-hm"

echo "== 13. hm exits with 2 (some lists skipped), DENY_ON=off: nobody is denied"
start_daemon HM="$T/partial-hm" DENY_ON=off
denied && bad "request was denied although DENY_ON is off" || ok "request was released"
grep -qF '<4>hm skipped some mirror lists (exit code 2)' "$LOG" && ! grep -q 'FAILED' "$LOG" \
    && ok "partial result logged as a warning, not as a failure" \
    || bad "partial result not logged as expected"
stop_daemon

echo "== 14. DENY_ON=failure: a failure is denied, a partial result is not"
start_daemon HM="$T/partial-hm" DENY_ON=failure
denied && bad "partial result was denied at level failure" || ok "partial result does not block at level failure"
stop_daemon
start_daemon HM="$T/fail-hm" DENY_ON=failure
denied && ok "failure is denied (EPERM)" || bad "failure was not denied"
grep -qF '<3>hm FAILED (exit code 3)' "$LOG" && grep -q 'denying 1 of 1 held' "$LOG" \
    && ok "failure and denial are logged" || bad "failure or denial not logged"
stop_daemon

echo "== 15. DENY_ON=partial: a partial result and a failure are both denied"
start_daemon HM="$T/partial-hm" DENY_ON=partial
denied && ok "partial result is denied (EPERM)" || bad "partial result was not denied at level partial"
stop_daemon
start_daemon HM="$T/fail-hm" DENY_ON=partial
denied && ok "failure is denied (EPERM)" || bad "failure was not denied at level partial"
stop_daemon

echo "== 16. only processes that would trigger hm are denied; others that were held pass"
start_daemon HM="$T/slowfail-hm" DENY_ON=failure
( "$T/pacman" -- --sync "$CONF" > "$T/out.pac" 2>&1 ) & P1=$!
sleep 0.3
( cat "$CONF" > "$T/out.cat" 2>&1 ) & P2=$!
wait "$P1" "$P2"
! grep -q '^\[options\]' "$T/out.pac" && ok "the triggering process is denied" \
                                         || bad "the triggering process was not denied"
grep -q '^\[options\]' "$T/out.cat" \
    && ok "an unrelated process that was held is allowed and reads the file" \
    || bad "an unrelated process was denied"
grep -q 'denying 1 of 2 held' "$LOG" && ok "log says 1 of 2 held requests were denied" \
                                      || bad "denial count not logged as expected"
stop_daemon

echo "== 17. a retry within the cooldown goes through"
start_daemon HM="$T/fail-hm" DENY_ON=failure COOLDOWN=30
denied && ok "first start is denied" || bad "first start was not denied"
denied && bad "retry within the cooldown was denied" || ok "retry within the cooldown is let through"
n=$(started)
[[ $n -eq 1 ]] && ok "hm was not started again by the retry" || bad "hm was started $n times (expected 1)"
stop_daemon

echo "== 18. timeout and a hm that cannot be started are denied too"
start_daemon SLOW=20 HM_TIMEOUT=1 DENY_ON=failure
denied && ok "hm timeout: the request is denied" || bad "hm timeout: the request was not denied"
stop_daemon
start_daemon HM=/nonexistent DENY_ON=failure
denied && ok "hm cannot be started: the request is denied" || bad "hm cannot be started: not denied"
stop_daemon

echo "== 19. stopping the daemon never denies"
start_daemon SLOW=20 STOP_GRACE=1 DENY_ON=partial
( "$T/pacman" -- --sync "$CONF" > "$T/out.pac" 2>&1 ) & PP=$!
sleep 1
kill -TERM "$DPID"
wait "$PP" 2>/dev/null
wait "$DPID" 2>/dev/null; DPID=
grep -q '^\[options\]' "$T/out.pac" && ok "request held during shutdown is allowed, not denied" \
                                                  || bad "request was denied during shutdown"
pkill -f '^sleep 20$' 2>/dev/null

echo "== 20. hm is told about the deny mode (only when it is enabled)"
start_daemon HM="$T/env-hm" OUT="$T/env.out" DENY_ON=partial COOLDOWN=45
pac
sleep 0.3
[[ $(cat "$T/env.out" 2>/dev/null) == "partial 45" ]] && ok "hm gets HM_DENY_ON and HM_DENY_RETRY" \
                                                       || bad "hm environment: '$(cat "$T/env.out" 2>/dev/null)'"
stop_daemon
rm -f "$T/env.out"
start_daemon HM="$T/env-hm" OUT="$T/env.out" DENY_ON=off HM_DENY_ON=leftover HM_DENY_RETRY=1
pac
sleep 0.3
[[ $(cat "$T/env.out" 2>/dev/null) == "unset unset" ]] && ok "without DENY_ON hm gets neither variable" \
                                                        || bad "hm environment: '$(cat "$T/env.out" 2>/dev/null)'"
stop_daemon

echo "== 21. DENY_ON together with COOLDOWN=0 produces a warning at startup"
start_daemon DENY_ON=failure
grep -qF '<4>warning: DENY_ON is set with COOLDOWN=0' "$LOG" && ok "warning logged" || bad "warning missing"
stop_daemon

echo "== 22. the default is DENY_ON=partial"
start_daemon HM="$T/partial-hm"
denied && ok "without DENY_ON a partial result is denied" || bad "default does not deny a partial result"
grep -q 'DENY_ON=partial:' "$LOG" && ok "startup log names the active mode" || bad "startup log does not name DENY_ON"
stop_daemon

echo "== 23. a stop that also terminates hm (systemd signals the whole service) never denies"
start_daemon SLOW=20 STOP_GRACE=5 DENY_ON=partial
( "$T/pacman" -- --sync "$CONF" > "$T/out.pac" 2>&1 ) & PP=$!
sleep 1
pkill -TERM -f '^sleep 20$'                    # hm first: the hardest order for the daemon
kill -TERM "$DPID"
wait "$PP" 2>/dev/null
wait "$DPID" 2>/dev/null; DPID=
grep -q '^\[options\]' "$T/out.pac" && ok "request is allowed although hm was terminated during the stop" \
                                     || bad "request was denied during a stop that terminated hm"
grep -qF '<4>hm was terminated (exit code -15)' "$LOG" && ok "termination logged as a warning, not as a failure" \
                                                       || bad "termination not logged as expected"
pkill -f '^sleep 20$' 2>/dev/null

echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
