#!/usr/bin/env bash
# test-hm-api.sh - test the CachyOS API fallback of hm, the independence of the two APIs
# and compare the two CachyOS APIs.
#
# Usage:
#   ./test-hm-api.sh [--offline] [path/to/hm]
#
# Part 1: offline fallback tests using a stub curl (tests 1-6).
# Part 2: compares data and hm decisions from both real APIs (test 7).
# Part 3: measures response times of both real APIs (test 8).
# Part 4: offline tests of the independence of the APIs (tests 9-12): an outage of one API
#         leaves the lists of the other API working, lists without an API are never touched.
#
# No root needed. hm is only run with --dry-run.
# Reads /etc/pacman.conf and included mirrorlists.
# Nothing else on the system is modified.
#
# Tests that need a certain kind of list (CachyOS, Arch Linux, other) are skipped when
# the mirrorlists of this system do not have it.

set -u
export LC_ALL=C

SELF=$(readlink -f "$0")
OFFLINE=0
HM=

for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        -h|--help)
            printf 'usage: %s [--offline] [path/to/hm]\n' "$0"
            exit 0
            ;;
        *) HM=$arg ;;
    esac
done

HM=$(readlink -f "${HM:-${SELF%/*}/hm}")
[[ -f $HM ]] || {
    echo "hm not found: $HM" >&2
    exit 1
}

for tool in curl jq sed grep cmp diff sort awk uniq basename; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing tool: $tool" >&2
        exit 1
    }
done

"$HM" --list >/dev/null 2>&1 || {
    echo "'$HM --list' failed: this test needs a working /etc/pacman.conf with mirrorlists" >&2
    exit 1
}

# Read API addresses directly from hm.
const() {
    sed -n "s/^$1='\(.*\)'\$/\1/p" "$HM"
}

PRIMARY=$(const CACHYOS_API)
FALLBACK=$(const CACHYOS_API_FALLBACK)
ARCH=$(const ARCH_API)

[[ -n $PRIMARY && -n $FALLBACK && -n $ARCH ]] || {
    echo "cannot read the API addresses from $HM (CACHYOS_API_FALLBACK missing?)" >&2
    exit 1
}

T=$(mktemp -d /tmp/hmapitest.XXXXXX)
LOG=$T/curl.log

RUNS=20             # downloads of each real API in test 8
REQUEST_DELAY=0.5   # pause between two downloads in test 8

PASS=0
FAIL=0
SKIP=0

trap 'rm -rf "$T"' EXIT

ok() {
    printf 'PASS  %s\n' "$1"
    PASS=$((PASS + 1))
}

bad() {
    printf 'FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
}

skip() {
    printf 'SKIP  %s\n' "$1"
    SKIP=$((SKIP + 1))
}

note() {
    printf 'NOTE  %s\n' "$1"
}

has() {
    grep -qF -- "$2" <<<"$1"
}

# ---------------------------------------------------------------------------
# The mirrorlists of this system, classified the way hm does it (list_kind and the
# name of the list in the summary). Keep this in step with hm.
#   cachyos: the name contains "cachyos"      -> CachyOS API
#   arch:    mirrorlist, arch-mirrorlist      -> Arch Linux API
#   other:   everything else (chaotic, ...)   -> no API, never touched
# ---------------------------------------------------------------------------

list_kind() {
    local base

    base=$(basename -- "$1")
    base="${base%-mirrorlist}"
    [[ "$base" == mirrorlist ]] && base=arch

    if [[ "${1,,}" == *cachyos* ]]; then
        echo cachyos
    elif [[ "$base" == arch || "$base" == archlinux ]]; then
        echo arch
    else
        echo other
    fi
}

list_name() {
    local name

    name=$(basename -- "$1")
    [[ "$name" == mirrorlist ]] && name=arch
    echo "${name%-mirrorlist}"
}

# "active/disabled" Server counts of a file, as hm shows them for a list it left unchanged
counts_of() {
    printf '%s/%s' \
        "$(grep -c '^Server = ' "$1" || true)" \
        "$(grep -c '^#UH#Server = ' "$1" || true)"
}

declare -a LIST_PATH=() LIST_KIND=() LIST_NAME=()
HAS_CACHYOS=0
HAS_ARCH=0
HAS_OTHER=0

while IFS= read -r path; do
    [[ -n $path ]] || continue
    kind=$(list_kind "$path")
    LIST_PATH+=("$path")
    LIST_KIND+=("$kind")
    LIST_NAME+=("$(list_name "$path")")
    case $kind in
        cachyos) HAS_CACHYOS=1 ;;
        arch)    HAS_ARCH=1 ;;
        other)   HAS_OTHER=1 ;;
    esac
done < <("$HM" --list)

note "mirrorlists of this system: $(for i in "${!LIST_PATH[@]}"; do printf '%s(%s) ' "${LIST_NAME[$i]}" "${LIST_KIND[$i]}"; done)"

# ---------------------------------------------------------------------------
# Canned data and stub curl
# ---------------------------------------------------------------------------

cat > "$T/cachyos.json" <<'EOF'
{"mirrors": [
  {"url": "https://good.example.org/cachyos/", "country_code": "DE", "delay_seconds": 0,
   "overall_status": "healthy",
   "checks": [{"path": "x86_64/cachyos/cachyos.db", "status": "synced"},
              {"path": "x86_64_v3/cachyos-v3/cachyos-v3.db", "status": "synced"},
              {"path": "x86_64_v4/cachyos-v4/cachyos-v4.db", "status": "synced"}]},
  {"url": "https://bad.example.org/cachyos/", "country_code": "US", "delay_seconds": null,
   "overall_status": "error",
   "checks": [{"path": "x86_64/cachyos/cachyos.db", "status": "error"}]}
]}
EOF

cat > "$T/arch.json" <<'EOF'
{"urls": [
  {"url": "https://arch.example.org/archlinux/", "protocol": "https", "active": true,
   "last_sync": "2026-10-30T07:00:00Z", "completion_pct": 1.0, "delay": 60}
]}
EOF

cat > "$T/broken.json" <<'EOF'
{"mirrors": [
  {"url": "https://a.example.org/cachyos/"},
  {"url": "https://b.example.org/cachyos/"},
  {"url": "https://c.example.org/cachyos/", "checks": []}
]}
EOF

mkdir "$T/bin"

cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
# Stub curl: serves canned data for the matching API address.

out=
url=

while [ $# -gt 0 ]; do
    case $1 in
        -o)
            out=$2
            shift
            ;;
        http://*|https://*)
            url=$1
            ;;
    esac
    shift
done

echo "$url" >> "$STUB_LOG"

case $url in
    "$STUB_URL_PRIMARY")  src=$STUB_PRIMARY ;;
    "$STUB_URL_FALLBACK") src=$STUB_FALLBACK ;;
    "$STUB_URL_ARCH")     src=$STUB_ARCH ;;
    *)
        echo "stub curl: unexpected address: $url" >&2
        exit 6
        ;;
esac

case $src in
    fail)
        echo 'curl: (22) The requested URL returned error: 503' >&2
        exit 22
        ;;
    bad)
        echo '{"mirrors": "nope"}' > "$out"
        ;;
    *)
        cp -- "$src" "$out"
        ;;
esac
EOF

chmod +x "$T/bin/curl"

# run_hm PRIMARY FALLBACK [ARCH]
# Each argument is a file with canned data, "fail" (download error) or "bad" (not mirror
# data). Sets OUT, ERR and RC.

run_hm() {
    : > "$LOG"

    OUT=$(env PATH="$T/bin:$PATH" STUB_LOG="$LOG" \
        STUB_URL_PRIMARY="$PRIMARY" \
        STUB_URL_FALLBACK="$FALLBACK" \
        STUB_URL_ARCH="$ARCH" \
        STUB_PRIMARY="$1" \
        STUB_FALLBACK="$2" \
        STUB_ARCH="${3:-$T/arch.json}" \
        "$HM" --dry-run 2>"$T/err")

    RC=$?
    ERR=$(<"$T/err")
}

requested() {
    grep -qxF -- "$1" "$LOG"
}

# ---------------------------------------------------------------------------
# Part 1: fallback behaviour
# ---------------------------------------------------------------------------

echo "== 1. primary API works: fallback is neither requested nor mentioned"

if (( ! HAS_CACHYOS )); then
    skip "no CachyOS mirrorlist on this system: tests 1-4 need one"
    BASE_OUT=
else
    run_hm "$T/cachyos.json" fail
    BASE_OUT=$OUT

    requested "$PRIMARY" \
        && ok "primary API requested" \
        || bad "primary API not requested"

    requested "$FALLBACK" \
        && bad "fallback API requested although primary works" \
        || ok "fallback API not requested"

    has "$ERR" 'fallback' \
        && bad "hm mentions a fallback: $ERR" \
        || ok "no fallback message"

    echo "== 2. primary download fails: fallback is used"

    run_hm fail "$T/cachyos.json"

    requested "$FALLBACK" \
        && ok "fallback API requested" \
        || bad "fallback API not requested"

    has "$ERR" 'using the fallback' \
        && ok "message says fallback is used" \
        || bad "message missing: $ERR"

    has "$ERR" "$PRIMARY" && has "$ERR" "$FALLBACK" \
        && ok "message names both addresses" \
        || bad "message does not name both addresses"

    has "$ERR" '503' \
        && ok "message contains the curl error" \
        || bad "reason missing"

    if [[ $OUT == "$BASE_OUT" ]]; then
        ok "same result as with primary API"
    else
        bad "result differs from primary API"
        diff <(printf '%s\n' "$BASE_OUT") <(printf '%s\n' "$OUT")
    fi

    echo "== 3. primary returns invalid mirror data: fallback is used"

    run_hm bad "$T/cachyos.json"

    has "$ERR" 'using the fallback' && has "$ERR" 'invalid or incomplete response' \
        && ok "fallback used, reason named" \
        || bad "unexpected message: $ERR"

    [[ $OUT == "$BASE_OUT" ]] \
        && ok "same result as with primary API" \
        || bad "result differs"

    echo "== 4. primary has more than half of its entries malformed"

    run_hm "$T/broken.json" "$T/cachyos.json"

    has "$ERR" 'using the fallback' && has "$ERR" 'looks broken' \
        && ok "fallback used, reason named" \
        || bad "unexpected message: $ERR"

    [[ $OUT == "$BASE_OUT" ]] \
        && ok "same result as with primary API" \
        || bad "result differs"
fi

echo "== 5. every needed API unusable: no list can be checked, exit 3"

if (( ! HAS_CACHYOS && ! HAS_ARCH )); then
    skip "no CachyOS or Arch Linux mirrorlist on this system"
else
    run_hm fail bad fail

    [[ $RC -eq 3 ]] \
        && ok "exit status 3 (mirror status unavailable)" \
        || bad "exit status $RC (expected 3)"

    has "$ERR" 'cannot get the mirror status:' \
        && ok "error says that the mirror status cannot be obtained" \
        || bad "unexpected message: $ERR"

    if (( HAS_CACHYOS )); then
        has "$ERR" 'CachyOS: ' && has "$ERR" "$PRIMARY" && has "$ERR" "$FALLBACK" \
            && ok "error names CachyOS and both of its addresses" \
            || bad "CachyOS error incomplete: $ERR"
    else
        has "$ERR" 'CachyOS: ' \
            && bad "error mentions CachyOS although no CachyOS list exists: $ERR" \
            || ok "CachyOS not mentioned (no CachyOS list on this system)"
    fi

    if (( HAS_ARCH )); then
        has "$ERR" 'Arch Linux: ' \
            && ok "error names the Arch Linux API" \
            || bad "Arch Linux error missing: $ERR"
    else
        has "$ERR" 'Arch Linux: ' \
            && bad "error mentions Arch Linux although no Arch list exists: $ERR" \
            || ok "Arch Linux not mentioned (no Arch list on this system)"
    fi

    has "$ERR" 'using the fallback' \
        && bad "claims to use the fallback" \
        || ok "does not claim to use the fallback"
fi

echo "== 6. Arch Linux API has no fallback: its failure makes the Arch list unavailable (exit 3)"

if (( ! HAS_ARCH )); then
    skip "no Arch Linux mirrorlist on this system"
else
    run_hm "$T/cachyos.json" fail fail

    [[ $RC -eq 3 ]] \
        && ok "exit status 3" \
        || bad "exit status $RC (expected 3): $ERR"

    has "$ERR" 'Arch Linux: download failed' \
        && ok "error names the Arch Linux API and the reason" \
        || bad "unexpected message: $ERR"

    [[ $(grep -cxF -- "$ARCH" "$LOG") -eq 1 ]] \
        && ok "the Arch Linux API was requested once (no fallback address)" \
        || bad "the Arch Linux API was requested $(grep -cxF -- "$ARCH" "$LOG") times"
fi

# ---------------------------------------------------------------------------
# Part 2: compare the two real APIs
# ---------------------------------------------------------------------------

derive() {
    local arch

    jq -r '
        .mirrors[]
        | select(.url | type == "string")
        | "known " + (.url | sub("/+$"; ""))
    ' "$1" | sort

    for arch in x86_64 x86_64_v3 x86_64_v4; do
        jq -r --arg architecture "$arch" '
            .mirrors[]
            | select((.url | type == "string") and (.checks | type == "array"))
            | select(.url | startswith("https://"))
            | [ .checks[]
                | select((.path | type == "string") and (.path | startswith($architecture + "/")))
                | .status
              ] as $checks
            | select(($checks | length) > 0 and all($checks[]; . == "synced"))
            | .url
            | sub("/+$"; "")
        ' "$1" | sed "s/^/$arch /" | sort
    done
}

echo "== 7. both real APIs give the same result"

if [[ $OFFLINE -eq 1 ]]; then
    skip "--offline"
elif ! curl -fsSL --connect-timeout 5 --max-time 10 "$PRIMARY" -o "$T/live-primary.json" ||
     ! curl -fsSL --connect-timeout 5 --max-time 10 "$FALLBACK" -o "$T/live-fallback.json" ||
     ! curl -fsSL --connect-timeout 5 --max-time 10 "$ARCH" -o "$T/live-arch.json"; then
    skip "cannot download the real APIs (network or HTTP error)"
elif ! jq -e '.mirrors | type == "array"' "$T/live-primary.json" >/dev/null 2>&1 ||
     ! jq -e '.mirrors | type == "array"' "$T/live-fallback.json" >/dev/null 2>&1; then
    bad "a real API did not return mirror data"
else
    derive "$T/live-primary.json" > "$T/derived-primary"
    derive "$T/live-fallback.json" > "$T/derived-fallback"

    [[ -s $T/derived-primary ]] \
        && ok "primary API: $(grep -c . "$T/derived-primary") derived entries" \
        || bad "primary API gave no mirrors"

    if cmp -s "$T/derived-primary" "$T/derived-fallback"; then
        ok "known and healthy mirrors (per architecture) are identical"
    else
        bad "known/healthy mirrors differ (primary vs fallback)"
        diff "$T/derived-primary" "$T/derived-fallback"
    fi

    run_hm "$T/live-primary.json" fail "$T/live-arch.json"
    OUT_PRIMARY=$OUT

    run_hm "$T/live-fallback.json" fail "$T/live-arch.json"
    OUT_FALLBACK=$OUT

    if [[ $OUT_PRIMARY == "$OUT_FALLBACK" ]]; then
        ok "hm makes the same decisions for both API responses"
    else
        bad "hm makes different decisions"
        diff <(printf '%s\n' "$OUT_PRIMARY") <(printf '%s\n' "$OUT_FALLBACK")
    fi

    if cmp -s <(jq -S . "$T/live-primary.json") <(jq -S . "$T/live-fallback.json"); then
        note "responses are identical after key normalization (jq -S)"
    else
        note "responses differ in content or fields not used by hm"
    fi
fi

# ---------------------------------------------------------------------------
# Part 3: measure real API response times
# ---------------------------------------------------------------------------

# median of the numbers in file $1 ("n/a" if there are none)
median() {
    sort -n "$1" | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) {
                print "n/a"
            } else if (NR % 2) {
                printf "%.6f\n", a[(NR + 1) / 2]
            } else {
                printf "%.6f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2
            }
        }
    '
}

# smallest of the numbers in file $1 ("n/a" if there are none)
fastest() {
    sort -n "$1" | awk '
        NR == 1 { printf "%.6f\n", $1; found = 1 }
        END { if (!found) print "n/a" }
    '
}

# seconds -> "123.4 ms"
ms() {
    awk -v t="$1" 'BEGIN {
        if (t == "n/a") print "n/a"
        else printf "%.1f ms", t * 1000
    }'
}

echo "== 8. response time of the two real APIs ($RUNS downloads each, alternating)"

if [[ $OFFLINE -eq 1 ]]; then
    skip "--offline"
else
    for which in primary fallback; do
        : > "$T/$which-ttfb"
        : > "$T/$which-total"
        : > "$T/$which-errors"
    done

    # Warm-up: one request to each API, not included in the measurements.
    for url in "$PRIMARY" "$FALLBACK"; do
        curl -sS --connect-timeout 5 --max-time 10 \
            -o /dev/null "$url" >/dev/null 2>&1
        sleep "$REQUEST_DELAY"
    done

    # Alternate the request order and keep a short delay between requests.
    for ((round = 1; round <= RUNS; round++)); do
        if (( round % 2 )); then
            order="primary fallback"
        else
            order="fallback primary"
        fi

        for which in $order; do
            if [[ $which == primary ]]; then
                url=$PRIMARY
            else
                url=$FALLBACK
            fi

            metrics=$(curl -sS --connect-timeout 5 --max-time 10 \
                -o /dev/null \
                -w '%{http_code}\t%{time_starttransfer}\t%{time_total}\t%{size_download}' \
                "$url" 2>/dev/null)
            rc=$?

            IFS=$'\t' read -r http ttfb total bytes <<< "$metrics"

            if [[ ${http:-000} == 200 && $rc -eq 0 && ${bytes:-0} -gt 0 ]]; then
                printf '%s\n' "$ttfb" >> "$T/$which-ttfb"
                printf '%s\n' "$total" >> "$T/$which-total"
            else
                printf 'HTTP=%s curl_exit=%s\n' "${http:-000}" "$rc" >> "$T/$which-errors"
            fi

            sleep "$REQUEST_DELAY"
        done
    done

    for which in primary fallback; do
        if [[ $which == primary ]]; then
            url=$PRIMARY
        else
            url=$FALLBACK
        fi

        n=$(grep -c . "$T/$which-total")

        if [[ $n -eq $RUNS ]]; then
            ok "$which answered all $RUNS downloads (HTTP 200)"
        else
            note "$which answered only $n of $RUNS downloads (HTTP 200)"
            while read -r count desc; do
                note "$which: ${count}x $desc"
            done < <(sort "$T/$which-errors" | uniq -c)
        fi

        note "$which: median TTFB $(ms "$(median "$T/$which-ttfb")"), median total $(ms "$(median "$T/$which-total")"), fastest total $(ms "$(fastest "$T/$which-total")")  $url"
    done

    mp=$(median "$T/primary-total")
    mf=$(median "$T/fallback-total")

    if [[ $mp == n/a || $mf == n/a ]]; then
        note "not enough successful responses to compare the two APIs"
    elif awk -v p="$mp" -v f="$mf" 'BEGIN { exit !(p <= f) }'; then
        delta=$(awk -v p="$mp" -v f="$mf" 'BEGIN { printf "%.1f", (f - p) * 1000 }')
        note "primary is faster by median total time: ${delta} ms"
    else
        delta=$(awk -v p="$mp" -v f="$mf" 'BEGIN { printf "%.1f", (p - f) * 1000 }')
        note "primary is slower by median total time: ${delta} ms"
    fi

    note "each download uses a new curl process and a fresh connection; timings never fail the test"
fi

# ---------------------------------------------------------------------------
# Part 4: the two APIs are independent of each other
# ---------------------------------------------------------------------------

# The entry of the list $1 in the mirror summary of the last run (empty if there is none).
summary_entry() {
    grep -m1 '^==== mirror summary' <<<"$OUT" |
        sed -e 's/^==== mirror summary ([^)]*): //' -e 's/ ====$//' |
        tr '|' '\n' |
        sed -e 's/^ *//' -e 's/ *$//' |
        awk -v n="$1" 'index($0, n " (") == 1 { print; exit }'
}

# Check the last run (an outage of the API of kind $1, the other API working):
#   - the lists of the kind $1 are left as they are, marked "ERR" with their
#     current counts, reported as left as they are and not part of an update;
#   - the lists of the other API are evaluated (an entry that is not "unavailable");
#   - the other lists (no API) show only "name (active)" and are never part of an update.
# Prints every problem found; returns 1 if there is any.
verify_state() {
    local down=$1 i name path kind entry problems=0

    for i in "${!LIST_PATH[@]}"; do
        name=${LIST_NAME[$i]}
        path=${LIST_PATH[$i]}
        kind=${LIST_KIND[$i]}
        entry=$(summary_entry "$name")

        if [[ $kind == "$down" ]]; then
            if [[ $entry != "$name ($(counts_of "$path"), ERR)" ]]; then
                printf '      %s: expected "%s (%s, ERR)", got "%s"\n' \
                    "$name" "$name" "$(counts_of "$path")" "$entry"
                problems=1
            fi
            if ! has "$OUT" "hm: left as it is (mirror status unavailable): $name"; then
                printf '      %s: not reported as left as it is\n' "$name"
                problems=1
            fi
            if has "$OUT" "hm: would update $path"; then
                printf '      %s: would be updated although its API is unavailable\n' "$name"
                problems=1
            fi
        elif [[ $kind == other ]]; then
            if [[ $entry != "$name ($(grep -c '^Server = ' "$path" || true))" ]]; then
                printf '      %s: expected "%s (N)", got "%s"\n' "$name" "$name" "$entry"
                problems=1
            fi
            if has "$OUT" "hm: left as it is (mirror status unavailable): $name" ||
               has "$OUT" "hm: would update $path"; then
                printf '      %s: a list without an API was touched or called unavailable\n' "$name"
                problems=1
            fi
        else
            if [[ -z $entry || $entry == *', ERR)' ]]; then
                printf '      %s: should have been evaluated, got "%s"\n' "$name" "$entry"
                problems=1
            fi
            if has "$OUT" "hm: left as it is (mirror status unavailable): $name"; then
                printf '      %s: reported unavailable although its API works\n' "$name"
                problems=1
            fi
        fi
    done

    return "$problems"
}

echo "== 9. Arch Linux API down, CachyOS works: CachyOS lists are checked, Arch list unavailable"

if (( ! HAS_ARCH || ! HAS_CACHYOS )); then
    skip "needs both a CachyOS and an Arch Linux mirrorlist on this system"
else
    run_hm "$T/cachyos.json" fail fail

    [[ $RC -eq 3 ]] \
        && ok "exit status 3" \
        || bad "exit status $RC (expected 3): $ERR"

    if verify_state arch; then
        ok "Arch lists unavailable and untouched, CachyOS lists evaluated, other lists untouched"
    else
        bad "wrong state of the lists (see above)"
    fi

    has "$ERR" 'mirror status unavailable' && has "$ERR" 'Arch Linux: download failed' \
        && ok "warning names the Arch Linux API and the reason" \
        || bad "unexpected message: $ERR"

    has "$ERR" 'CachyOS: ' \
        && bad "warning mentions CachyOS: $ERR" \
        || ok "CachyOS is not reported as failed"
fi

echo "== 10. both CachyOS addresses down, Arch Linux works: Arch list is checked, CachyOS lists unavailable"

if (( ! HAS_ARCH || ! HAS_CACHYOS )); then
    skip "needs both a CachyOS and an Arch Linux mirrorlist on this system"
else
    run_hm fail fail "$T/arch.json"

    [[ $RC -eq 3 ]] \
        && ok "exit status 3" \
        || bad "exit status $RC (expected 3): $ERR"

    if verify_state cachyos; then
        ok "CachyOS lists unavailable and untouched, Arch list evaluated, other lists untouched"
    else
        bad "wrong state of the lists (see above)"
    fi

    has "$ERR" 'mirror status unavailable' && has "$ERR" 'CachyOS: ' &&
        has "$ERR" "$PRIMARY" && has "$ERR" "$FALLBACK" \
        && ok "warning names CachyOS and both addresses" \
        || bad "unexpected message: $ERR"

    has "$ERR" 'Arch Linux: ' \
        && bad "warning mentions the Arch Linux API: $ERR" \
        || ok "Arch Linux is not reported as failed"
fi

echo "== 11. lists without an API are never touched and never unavailable"

if (( ! HAS_OTHER )); then
    skip "no mirrorlist without an API (chaotic, ...) on this system"
elif (( HAS_CACHYOS )); then
    run_hm "$T/cachyos.json" fail fail    # the Arch Linux API is down
    if verify_state arch; then
        ok "other lists show only their number of active mirrors during an Arch Linux outage"
    else
        bad "wrong state of the lists (see above)"
    fi
elif (( HAS_ARCH )); then
    run_hm fail fail "$T/arch.json"       # both CachyOS addresses are down
    if verify_state cachyos; then
        ok "other lists show only their number of active mirrors during a CachyOS outage"
    else
        bad "wrong state of the lists (see above)"
    fi
else
    skip "no CachyOS or Arch Linux mirrorlist on this system"
fi

echo "== 12. an API that no list uses is not downloaded"

if (( HAS_CACHYOS && HAS_ARCH )); then
    skip "this system has both CachyOS and Arch Linux lists"
elif (( ! HAS_CACHYOS && ! HAS_ARCH )); then
    skip "no CachyOS or Arch Linux mirrorlist on this system"
elif (( HAS_CACHYOS )); then
    run_hm "$T/cachyos.json" fail fail
    requested "$ARCH" \
        && bad "the Arch Linux API was requested although no Arch list exists" \
        || ok "the Arch Linux API was not requested"
    [[ $RC -ne 3 ]] \
        && ok "an unusable Arch Linux API does not matter (exit status $RC)" \
        || bad "exit status 3 although only the unused API failed: $ERR"
else
    run_hm fail fail "$T/arch.json"
    if requested "$PRIMARY" || requested "$FALLBACK"; then
        bad "a CachyOS address was requested although no CachyOS list exists"
    else
        ok "no CachyOS address was requested"
    fi
    [[ $RC -ne 3 ]] \
        && ok "an unusable CachyOS API does not matter (exit status $RC)" \
        || bad "exit status 3 although only the unused API failed: $ERR"
fi

echo
echo "passed: $PASS, failed: $FAIL, skipped: $SKIP"

[[ $FAIL -eq 0 ]]
