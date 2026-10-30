#!/usr/bin/env bash
# test-hm-api.sh - test the CachyOS API fallback of hm and compare the two APIs.
#
# Usage:
#   ./test-hm-api.sh [--offline] [path/to/hm]
#
# Part 1: offline fallback tests using a stub curl.
# Part 2: compares data and hm decisions from both real APIs.
# Part 3: measures response times of both real APIs.
#
# No root needed. hm is only run with --dry-run.
# Reads /etc/pacman.conf and included mirrorlists.
# Nothing else on the system is modified.

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

for tool in curl jq sed grep cmp diff sort awk; do
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

RUNS=20
REQUEST_DELAY=0.5

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
# Sets OUT, ERR and RC.

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

echo "== 5. both APIs unusable: error, exit 1"

run_hm fail bad

[[ $RC -eq 1 ]] \
    && ok "exit status 1" \
    || bad "exit status $RC (expected 1)"

has "$ERR" 'cannot get CachyOS mirror status' &&
    has "$ERR" "$PRIMARY" &&
    has "$ERR" "$FALLBACK" \
    && ok "error names both addresses" \
    || bad "unexpected message: $ERR"

has "$ERR" 'using the fallback' \
    && bad "claims to use the fallback" \
    || ok "does not claim to use the fallback"

echo "== 6. Arch Linux API has no fallback"

run_hm "$T/cachyos.json" fail fail

[[ $RC -eq 1 ]] && has "$ERR" 'cannot download Arch Linux mirror status' \
    && ok "exit 1 with the Arch error" \
    || bad "exit $RC: $ERR"

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
    : > "$T/timings"
    : > "$T/primary-ttfb"
    : > "$T/primary-total"
    : > "$T/fallback-ttfb"
    : > "$T/fallback-total"

    # Warm-up: one request to each API, not included in the measurements.
    for url in "$PRIMARY" "$FALLBACK"; do
        curl -sS --connect-timeout 5 --max-time 10 \
            -o /dev/null "$url" >/dev/null 2>&1
        sleep "$REQUEST_DELAY"
    done

    # Alternate request order and keep a short delay between requests.
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
                -w '%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{size_download}' \
                "$url" 2>/dev/null)
            rc=$?

            printf '%s\t%s\t%d\n' "$which" "$metrics" "$rc" >> "$T/timings"

            IFS=$'\t' read -r http dns tcp tls ttfb total bytes <<< "$metrics"

            if [[ $http == 200 && $rc -eq 0 && $bytes -gt 0 ]]; then
                printf '%s\n' "$ttfb" >> "$T/$which-ttfb"
                printf '%s\n' "$total" >> "$T/$which-total"
            fi

            sleep "$REQUEST_DELAY"
        done
    done

    echo
    echo "Successful HTTP 200 responses:"

    awk -F '\t' -v runs="$RUNS" '
        $2 == 200 && $9 == 0 && $8 > 0 { count[$1]++ }
        END {
            printf "primary:  %d/%d\n", count["primary"], runs
            printf "fallback: %d/%d\n", count["fallback"], runs
        }
    ' "$T/timings"

    echo
    echo "Median response times (only HTTP 200 responses):"

    for which in primary fallback; do
        ttfb=$(median "$T/$which-ttfb")
        total=$(median "$T/$which-total")

        if [[ $which == primary ]]; then
            url=$PRIMARY
        else
            url=$FALLBACK
        fi

        printf '%-9s TTFB: %-12s TOTAL: %-12s %s\n' \
            "$which" "$(ms "$ttfb")" "$(ms "$total")" "$url"
    done

    echo
    echo "HTTP / connection errors:"

    awk -F '\t' '
        $2 != 200 || $9 != 0 {
            printf "%-9s HTTP=%s curl_exit=%s\n", $1, $2, $9
        }
    ' "$T/timings"

    mp=$(median "$T/primary-total")
    mf=$(median "$T/fallback-total")

    echo
    if [[ $mp == n/a || $mf == n/a ]]; then
        note "not enough successful HTTP 200 responses to compare both APIs"
    elif awk -v p="$mp" -v f="$mf" 'BEGIN { exit !(p <= f) }'; then
        delta=$(awk -v p="$mp" -v f="$mf" 'BEGIN { printf "%.1f", (f - p) * 1000 }')
        note "primary is faster by median TOTAL: ${delta} ms"
    else
        delta=$(awk -v p="$mp" -v f="$mf" 'BEGIN { printf "%.1f", (p - f) * 1000 }')
        note "primary is slower by median TOTAL: ${delta} ms"
    fi

    note "each measurement uses a new curl process and a fresh connection"
    note "HTTP errors are reported separately and excluded from timing medians"
fi

echo
echo "passed: $PASS, failed: $FAIL, skipped: $SKIP"

[[ $FAIL -eq 0 ]]
