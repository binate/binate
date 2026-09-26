#!/bin/sh
# perf/ab-binaries.sh — A/B two already-built binaries on the same workload.
#
# Typical use: build the same program with two compilers (before / after a
# codegen change) and compare the resulting binaries.  Each round runs A and B
# once, INTERLEAVED, and ALTERNATES the order (A,B then B,A then …) so neither
# concurrent load nor monotonic thermal drift becomes a consistent bias (see
# explorations/perf-optimization-guide.md §4).
#
# Metrics, per arm, best (min) and median across rounds:
#   - instructions retired (macOS `/usr/bin/time -l`) — the noise-immune metric
#     on Apple Silicon: independent of load, frequency, and preemption.
#   - user CPU seconds (the `user` field of the same run).
# Both are also reported as the B/A ratio of the medians.  On a host whose
# `time` has no `-l` (not macOS), only user CPU is reported.
#
# Before timing, A and B are run once each and their stdout compared: a codegen
# A/B is only meaningful when both binaries do the identical work.  A mismatch
# aborts (override with --no-check).
#
# Usage: perf/ab-binaries.sh [--rounds N] [--no-check] A_BIN B_BIN [args...]
#   --rounds N    interleaved, order-alternating rounds (default 7)
#   --no-check    skip the stdout-identity check
#   args...       passed to both binaries on every run

ROUNDS=7
CHECK=1
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS="$2"; shift 2 ;;
        --no-check) CHECK=0; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
if [ $# -lt 2 ]; then
    echo "usage: $0 [--rounds N] [--no-check] A_BIN B_BIN [args...]" >&2
    exit 2
fi
A="$1"; B="$2"; shift 2
for bin in "$A" "$B"; do
    if [ ! -x "$bin" ]; then echo "not an executable: $bin" >&2; exit 2; fi
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ab_binaries_XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

HAVE_INSNS=0
if /usr/bin/time -l true >/dev/null 2>"$TMP/probe" && grep -q "instructions retired" "$TMP/probe"; then
    HAVE_INSNS=1
fi

if [ "$CHECK" -eq 1 ]; then
    "$A" "$@" >"$TMP/a.out" 2>/dev/null
    "$B" "$@" >"$TMP/b.out" 2>/dev/null
    if ! cmp -s "$TMP/a.out" "$TMP/b.out"; then
        echo "error: A and B produce different stdout — not a like-for-like A/B" >&2
        exit 1
    fi
fi

# run_one BIN ARGS... — one timed run of BIN; its time(1) report lands in $TMP/run.
run_one() {
    bin="$1"; shift
    if [ "$HAVE_INSNS" -eq 1 ]; then
        /usr/bin/time -l "$bin" "$@" >/dev/null 2>"$TMP/run" || true
    else
        /usr/bin/time -p "$bin" "$@" >/dev/null 2>"$TMP/run" || true
    fi
}
# record TAG — appends "insns user" from $TMP/run to $TMP/TAG.
record() {
    # macOS `time -l` prints "<real> real <user> user <sys> sys" on line 1;
    # `time -p` prints "user <secs>" on its own line.
    if [ "$HAVE_INSNS" -eq 1 ]; then
        u=$(head -1 "$TMP/run" | awk '{for (i = 1; i < NF; i++) if ($(i+1) == "user") print $i}')
        n=$(awk '/instructions retired/ {print $1}' "$TMP/run")
    else
        u=$(awk '$1 == "user" {print $2}' "$TMP/run")
        n=0
    fi
    echo "$n $u" >>"$TMP/$1"
}

echo "A: $A"
echo "B: $B"
echo "args: $*"
echo "round  order   A_insns        B_insns        A_user  B_user"
r=1
while [ "$r" -le "$ROUNDS" ]; do
    if [ $((r % 2)) -eq 1 ]; then
        order="A,B"
        run_one "$A" "$@"; record a
        run_one "$B" "$@"; record b
    else
        order="B,A"
        run_one "$B" "$@"; record b
        run_one "$A" "$@"; record a
    fi
    la=$(tail -1 "$TMP/a"); lb=$(tail -1 "$TMP/b")
    printf '%-6s %-7s %-14s %-14s %-7s %s\n' "$r" "$order" "${la% *}" "${lb% *}" "${la#* }" "${lb#* }"
    r=$((r + 1))
done

# colstat FILE COL — prints "best median" of column COL (1 = insns, 2 = user).
colstat() {
    awk -v c="$2" '{print $c}' "$1" | sort -g >"$TMP/col"
    cnt=$(wc -l <"$TMP/col" | tr -d ' ')
    best=$(head -1 "$TMP/col")
    mid=$(( (cnt + 1) / 2 ))
    med=$(sed -n "${mid}p" "$TMP/col")
    echo "$best $med"
}
set -- $(colstat "$TMP/a" 2); a_ub=$1; a_um=$2
set -- $(colstat "$TMP/b" 2); b_ub=$1; b_um=$2
echo
if [ "$HAVE_INSNS" -eq 1 ]; then
    set -- $(colstat "$TMP/a" 1); a_nb=$1; a_nm=$2
    set -- $(colstat "$TMP/b" 1); b_nb=$1; b_nm=$2
    echo "instructions retired  A best $a_nb median $a_nm"
    echo "                      B best $b_nb median $b_nm"
    awk -v a="$a_nm" -v b="$b_nm" 'BEGIN { printf "                      B/A (median) %.4f  (%+.2f%%)\n", b / a, (b - a) / a * 100 }'
fi
echo "user CPU seconds      A best $a_ub median $a_um"
echo "                      B best $b_ub median $b_um"
awk -v a="$a_um" -v b="$b_um" 'BEGIN { if (a > 0) printf "                      B/A (median) %.4f  (%+.2f%%)\n", b / a, (b - a) / a * 100 }'
