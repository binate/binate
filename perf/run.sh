#!/bin/sh
# Usage: ./perf/run.sh <mode> [filter...]
#
# Runs performance tests against the specified backend mode and reports
# per-test compile and run timings (ms resolution).
#
# Unlike conformance tests, these are not pass/fail but report timing.
# Each test also verifies its output against NNN_name.expected, so
# correctness regressions still surface.
#
# Runners live in perf/runners/<mode>.sh. Each runner defines:
#   runner_setup    (optional) one-time setup
#   runner_compile  (optional) compile the test; if omitted, the mode
#                   has no compile step and compile= is reported as "-"
#   runner_run      (required) run the test; output goes to stdout
#   runner_cleanup  (optional) one-time cleanup
#
# Skip: NNN_name.skip.<mode> marks a test as skipped in that mode
# (one-line reason in the file).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"
export SCRIPT_DIR BINATE_DIR BOOTSTRAP_DIR

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 <mode> [filter...]"
    echo ""
    echo "Mode argument forms:"
    echo "  <name>                single mode (e.g. boot-comp)"
    echo "  <name>,<name>,...     comma-separated list of modes"
    echo "  <modeset>             mode set file (e.g. basic, all)"
    echo ""
    echo "Modes:"
    for r in "$SCRIPT_DIR"/runners/*.sh; do
        [ -f "$r" ] || continue
        rname="$(basename "$r" .sh)"
        desc=$(grep '^# Runner:' "$r" | head -1 | sed 's/^# Runner: //')
        printf "  %-20s %s\n" "$rname" "$desc"
    done
    echo ""
    echo "Mode sets (from scripts/modesets/):"
    msd="$(cd "$(dirname "$0")/../scripts/modesets" && pwd)"
    for sf in "$msd"/*; do
        [ -f "$sf" ] || continue
        sname="$(basename "$sf")"
        modes="$(grep -v '^#' "$sf" | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
        printf "  %-20s %s\n" "$sname" "$modes"
    done
    exit 1
fi
shift

# Expand mode sets — reads from scripts/modesets/ files
MODESETS_DIR="$(cd "$(dirname "$0")/../scripts/modesets" && pwd)"
expand_set() {
    setfile="$MODESETS_DIR/$1"
    [ -f "$setfile" ] || return 1
    grep -v '^#' "$setfile" | grep -v '^$' | tr '\n' ' '
}

# Try mode set file first, then comma-separated list
MODES="$(expand_set "$MODE" 2>/dev/null)" || {
    case "$MODE" in
        *,*) MODES="$(echo "$MODE" | tr ',' ' ')" ;;
    esac
}

if [ -n "$MODES" ]; then
    overall_exit=0
    for m in $MODES; do
        echo "========================================"
        echo "=== Mode: $m"
        echo "========================================"
        "$0" "$m" "$@"
        rc=$?
        if [ $rc -ne 0 ]; then overall_exit=$rc; fi
        echo ""
    done
    exit $overall_exit
fi

RUNNER="$SCRIPT_DIR/runners/${MODE}.sh"
if [ ! -f "$RUNNER" ]; then
    echo "Unknown mode: $MODE"
    exit 1
fi
. "$RUNNER"

# Millisecond-resolution timing via perl (Time::HiRes is core since 5.8).
now() {
    perl -MTime::HiRes=time -e 'printf "%.3f", time()'
}

# Subtract two timestamps with ms precision.
delta() {
    perl -e "printf '%.3f', $2 - $1"
}

# Filter tests by substring (OR'd across filters).
matches_filter() {
    [ $# -lt 2 ] && return 0
    name="$1"; shift
    for f in "$@"; do
        case "$name" in *"$f"*) return 0;; esac
    done
    return 1
}

# Run setup (e.g. build gen1 for later modes).
if command -v runner_setup >/dev/null 2>&1; then
    runner_setup
fi
if command -v runner_cleanup >/dev/null 2>&1; then
    trap 'runner_cleanup' EXIT
fi

has_compile=0
if command -v runner_compile >/dev/null 2>&1; then
    has_compile=1
fi

for bn in "$SCRIPT_DIR"/*.bn; do
    [ -f "$bn" ] || continue
    name="$(basename "$bn" .bn)"
    if ! matches_filter "$name" "$@"; then
        continue
    fi

    skip_file="$SCRIPT_DIR/${name}.skip.${MODE}"
    if [ -f "$skip_file" ]; then
        printf "%-12s %-20s SKIP (%s)\n" "$MODE" "$name" "$(cat "$skip_file")"
        continue
    fi

    expected="$SCRIPT_DIR/${name}.expected"
    if [ ! -f "$expected" ]; then
        printf "%-12s %-20s SKIP (no expected file)\n" "$MODE" "$name"
        continue
    fi
    expected_content="$(cat "$expected")"

    tmpbin="/tmp/perf_${MODE}_${name}_$$"

    if [ "$has_compile" -eq 1 ]; then
        t0=$(now)
        compile_out=$(runner_compile "$bn" "$tmpbin" 2>&1)
        compile_rc=$?
        t1=$(now)
        compile_s="$(delta "$t0" "$t1")s"
        if [ $compile_rc -ne 0 ] || [ ! -x "$tmpbin" ]; then
            printf "%-12s %-20s compile=%-8s [COMPILE_ERROR]\n" \
                "$MODE" "$name" "$compile_s"
            echo "$compile_out" | sed 's/^/  /'
            rm -f "$tmpbin"
            continue
        fi
    else
        t1=$(now)
        compile_s="-"
    fi

    actual=$(runner_run "$bn" "$tmpbin" 2>&1)
    t2=$(now)
    run_s="$(delta "$t1" "$t2")s"
    rm -f "$tmpbin"

    if [ "$actual" = "$expected_content" ]; then
        status="PASS"
    else
        status="FAIL"
    fi
    printf "%-12s %-20s compile=%-8s run=%-8s [%s]\n" \
        "$MODE" "$name" "$compile_s" "$run_s" "$status"
    if [ "$status" = "FAIL" ]; then
        echo "  expected: $expected_content"
        echo "  actual:   $actual"
    fi
done
