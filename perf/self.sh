#!/bin/sh
# Usage: ./perf/self.sh [filter...]
#
# Self-hosting perf benchmarks: the toolchain operating on the toolchain (real,
# nontrivial workloads) — complementing the toy-program perf tests in
# perf/run.sh.  Each benchmark times ONE toolchain operation (ms resolution)
# and, where it produces output, verifies it so a correctness regression
# surfaces too.  A single timed run per benchmark (matching perf/run.sh's
# convention); no warmup / repetition.
#
# Benchmarks (filter by substring on the name):
#   bnc_compiles_bnc    gen1 (current-tree cmd/bnc, built by the BUILDER during
#                       setup) compiles cmd/bnc — compiler throughput on the
#                       largest real program.  -O0 output (like perf/run.sh's
#                       builder-comp compile), so the figure tracks bnc's own
#                       work rather than clang's -O2 backend time.
#   bni_runs_hello      compiled cmd/bni runs a hello-world program (single VM).
#   bni_runs_bni_hello  compiled cmd/bni runs cmd/bni running hello-world
#                       (double VM) — the builder-comp-int-int unit lane's
#                       per-shard floor, as one tracked number.
#
# Progress goes to stderr; a markdown results table goes to stdout (the
# perf-tests CI workflow feeds it to the run's step summary).  Exit is non-zero
# if any benchmark errors or mis-outputs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_DIR BINATE_DIR
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

IP="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
LP="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
HELLO="$SCRIPT_DIR/self/hello.bn"
HELLO_EXPECTED="Hello, world!"

# Millisecond-resolution timing (perl Time::HiRes is core since 5.8), matching
# perf/run.sh.
now()   { perl -MTime::HiRes=time -e 'printf "%.3f", time()'; }
delta() { perl -e "printf '%.3f', $2 - $1"; }

# matches_filter <name> [filters...] — true if no filters, or name contains one.
matches_filter() {
    [ "$#" -lt 2 ] && return 0
    _n="$1"; shift
    for f in "$@"; do case "$_n" in *"$f"*) return 0;; esac; done
    return 1
}

ROWS=""
FAILURES=0
FAILED_NAMES=""

# record <name> <secs> <status> <what> — append a markdown row + a stderr line.
record() {
    ROWS="$ROWS| \`$1\` | $4 | $2 | $3 |
"
    printf '%-20s time=%-9s [%s]\n' "$1" "$2" "$3" >&2
    if [ "$3" != PASS ]; then
        FAILURES=$((FAILURES + 1)); FAILED_NAMES="$FAILED_NAMES $1"
    fi
}

trap 'cleanup_compilers' EXIT

# Build the shared artifacts once: gen1 (GEN1_COMPILER, -O2) + compiled interp
# (COMPILED_INTERP, -O2).  build_interp_boot_comp does both.  Its build-progress
# echoes go to stdout, so redirect to stderr — stdout must stay pure markdown
# (the CI step feeds it verbatim to the run summary).
echo "Setup: building gen1 + compiled interp..." >&2
build_interp_boot_comp >&2

# --- bnc_compiles_bnc: gen1 compiles cmd/bnc (the largest real program) ---
if matches_filter bnc_compiles_bnc "$@"; then
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/perf_self_bnc_XXXXXX")"
    obin="$bdir/bnc_out"
    t0=$(now)
    log=$("$GEN1_COMPILER" -I "$IP" -L "$LP" --build-dir "$bdir" -o "$obin" "$BINATE_DIR/cmd/bnc" 2>&1)
    rc=$?
    t1=$(now)
    secs="$(delta "$t0" "$t1")s"
    status=PASS
    if [ "$rc" -ne 0 ] || [ ! -x "$obin" ]; then
        status=COMPILE_ERROR
        printf '%s\n' "$log" | sed 's/^/  /' >&2
    elif ! "$obin" --version >/dev/null 2>&1; then
        # The produced compiler must at least run (--version is the cheapest
        # liveness check that the emitted binary isn't corrupt).
        status=FAIL
    fi
    rm -rf "$bdir"
    record bnc_compiles_bnc "$secs" "$status" "gen1 compiles cmd/bnc (-O0 out)"
fi

# --- bni_runs_hello: compiled cmd/bni runs a real program (single VM) ---
if matches_filter bni_runs_hello "$@"; then
    t0=$(now)
    out=$("$COMPILED_INTERP" -I "$IP" -L "$LP" -main-file "$HELLO" 2>&1)
    rc=$?
    t1=$(now)
    secs="$(delta "$t0" "$t1")s"
    status=PASS
    if [ "$rc" -ne 0 ] || [ "$out" != "$HELLO_EXPECTED" ]; then
        status=FAIL
        printf '  expected: %s\n  actual:   %s\n' "$HELLO_EXPECTED" "$out" >&2
    fi
    record bni_runs_hello "$secs" "$status" "cmd/bni runs hello (single VM)"
fi

# --- bni_runs_bni_hello: cmd/bni runs cmd/bni runs hello (double VM) ---
if matches_filter bni_runs_bni_hello "$@"; then
    t0=$(now)
    out=$("$COMPILED_INTERP" -I "$IP" -L "$LP" -main-dir "$BINATE_DIR/cmd/bni" -- \
        -I "$IP" -L "$LP" -main-file "$HELLO" 2>&1)
    rc=$?
    t1=$(now)
    secs="$(delta "$t0" "$t1")s"
    status=PASS
    if [ "$rc" -ne 0 ] || [ "$out" != "$HELLO_EXPECTED" ]; then
        status=FAIL
        printf '  expected: %s\n  actual:   %s\n' "$HELLO_EXPECTED" "$out" >&2
    fi
    record bni_runs_bni_hello "$secs" "$status" "cmd/bni runs cmd/bni runs hello (double VM)"
fi

# --- markdown results table on stdout (for the CI step summary) ---
printf '## Self-hosting perf benchmarks\n\n'
printf 'The toolchain operating on the toolchain (single timed run each, seconds).\n\n'
printf '| benchmark | what | time | status |\n'
printf '| --- | --- | --- | --- |\n'
printf '%s' "$ROWS"
printf '\n'

if [ "$FAILURES" -gt 0 ]; then
    printf '**%d failure(s):**%s\n' "$FAILURES" "$FAILED_NAMES"
    echo "=== perf/self.sh: $FAILURES failure(s):$FAILED_NAMES ===" >&2
    exit 1
fi
