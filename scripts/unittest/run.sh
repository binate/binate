#!/bin/sh
# Usage: ./scripts/unittest/run.sh <mode> [filter...]
#
# Runs unit tests for all packages (or filtered packages) using the specified
# backend mode.
#
# Modes (chains of: boot=bootstrap, int=interpreter, comp=compiler):
#   boot                Go bootstrap interpreter runs -test directly
#   boot-comp           Bootstrap interprets bnc, which compiles and runs tests
#   boot-comp-int       Compiled bni runs --test natively
#   boot-comp-comp      Self-compiled compiler (gen1) runs --test
#   boot-comp-comp-comp Gen2 compiler runs --test
#
# Mode sets:
#   basic               boot, boot-comp, boot-comp-int
#   all                 boot, boot-comp, boot-comp-int, boot-comp-comp
#   full                all + boot-comp-comp-comp
#
# Filters select packages by substring match (e.g. "ir" matches "pkg/ir").
#
# Per-package xfail:
#   scripts/unittest/<pkg-with-slashes-replaced-by-dashes>.xfail.<mode>
#   e.g. scripts/unittest/pkg-rt.xfail.boot
#   Contents are the reason for the expected failure.

# Parse flags
VERBOSE=0
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        *)            break ;;
    esac
done
export VERBOSE QUIET

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 [-v|-q] <mode> [filter...]"
    echo ""
    echo "Runs unit tests for all packages (or filtered packages) using"
    echo "the specified backend mode."
    echo ""
    echo "Flags:"
    echo "  -v, --verbose   Show per-test PASS/FAIL output"
    echo "  -q, --quiet     Show only failures and summary"
    echo "  (default)       Show pass/fail per package, failures in detail"
    echo ""
    echo "Filters select packages by substring match (e.g. 'ir' matches"
    echo "'pkg/ir'). Multiple filters are OR'd."
    echo ""
    echo "Examples:"
    echo "  $0 boot                   Run all tests via bootstrap"
    echo "  $0 boot-comp interp       Run pkg/interp tests via compiler"
    echo "  $0 basic                  Run boot, boot-comp, boot-comp-int"
    echo "  $0 boot ir codegen        Run pkg/ir and pkg/codegen tests"
    echo ""
    echo "Modes:"
    for r in "$(dirname "$0")"/runners/*.sh; do
        [ -f "$r" ] || continue
        rname="$(basename "$r" .sh)"
        desc=$(grep '^# Runner:' "$r" | head -1 | sed 's/^# Runner: //')
        printf "  %-20s %s\n" "$rname" "$desc"
    done
    echo ""
    echo "Mode sets (from scripts/modesets/):"
    msd="$(cd "$(dirname "$0")/../modesets" && pwd)"
    for sf in "$msd"/*; do
        [ -f "$sf" ] || continue
        sname="$(basename "$sf")"
        modes="$(grep -v '^#' "$sf" | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
        printf "  %-20s %s\n" "$sname" "$modes"
    done
    echo ""
    echo "Xfail: scripts/unittest/<pkg-path>.xfail.<mode>"
    echo "  e.g. scripts/unittest/pkg-rt.xfail.boot"
    echo "  (slashes in package path replaced with dashes)"
    exit 1
fi
shift

# Expand mode sets — reads from scripts/modesets/ files
MODESETS_DIR="$(cd "$(dirname "$0")/../modesets" && pwd)"
expand_set() {
    local setfile="$MODESETS_DIR/$1"
    [ -f "$setfile" ] || return 1
    grep -v '^#' "$setfile" | grep -v '^$' | tr '\n' ' '
}

MODES="$(expand_set "$MODE" 2>/dev/null)" && {
    overall_exit=0
    for m in $MODES; do
        echo "========================================"
        echo "=== Mode: $m"
        echo "========================================"
        flags=""
        [ "$VERBOSE" -eq 1 ] && flags="-v"
        [ "$QUIET" -eq 1 ] && flags="-q"
        "$0" $flags "$m" "$@"
        rc=$?
        if [ $rc -ne 0 ]; then overall_exit=$rc; fi
        echo ""
    done
    exit $overall_exit
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"
export SCRIPT_DIR BINATE_DIR BOOTSTRAP_DIR

# Load the runner
RUNNER="$SCRIPT_DIR/runners/${MODE}.sh"
if [ ! -f "$RUNNER" ]; then
    echo "Unknown mode: $MODE"
    echo "Available modes:"
    for r in "$SCRIPT_DIR"/runners/*.sh; do
        [ -f "$r" ] || continue
        echo "  $(basename "$r" .sh)"
    done
    exit 1
fi
. "$RUNNER"

# Run setup
runner_setup

# Ensure cleanup runs on exit
trap 'runner_cleanup' EXIT

# Discover all packages with _test.bn files
PACKAGES=""
for testfile in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" -name '*_test.bn' 2>/dev/null); do
    [ -f "$testfile" ] || continue
    dir="$(dirname "$testfile")"
    # Convert absolute path to package path (e.g. /path/to/binate/pkg/ir -> pkg/ir)
    pkg="${dir#"$BINATE_DIR"/}"
    # Deduplicate
    case " $PACKAGES " in
        *" $pkg "*) ;;
        *) PACKAGES="$PACKAGES $pkg" ;;
    esac
done

passed=0
failed=0
xfailed=0
skipped=0
failures=""

for pkg in $PACKAGES; do
    # Apply filters (exact match on full package path)
    if [ $# -gt 0 ]; then
        match=0
        for f in "$@"; do
            if [ "$pkg" = "$f" ]; then match=1; break; fi
        done
        if [ "$match" -eq 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Check for xfail
    xfail_key="$(echo "$pkg" | tr '/' '-')"
    xfail_file="$SCRIPT_DIR/${xfail_key}.xfail.${MODE}"
    if [ -f "$xfail_file" ]; then
        reason="$(cat "$xfail_file")"
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $pkg ($reason)"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        xfailed=$((xfailed + 1))
        continue
    fi

    # Run tests with timing
    start_time=$(date +%s)
    output=$(runner_test "$pkg" 2>&1)
    rc=$?
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    if [ $rc -eq 0 ]; then
        count=$(echo "$output" | grep -o '[0-9]* passed' | head -1)
        if [ "$VERBOSE" -eq 1 ]; then
            echo "PASS: $pkg ($count) [${elapsed}s]"
        elif [ "$QUIET" -eq 0 ]; then
            printf "."
        fi
        passed=$((passed + 1))
    else
        if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
            echo ""
            echo "FAIL: $pkg [${elapsed}s]"
            echo "$output" | sed 's/^/  /' | tail -5
        fi
        failed=$((failed + 1))
        failures="$failures $pkg"
    fi
done

if [ "$VERBOSE" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    echo ""
fi
echo ""
echo "=== Summary ($MODE): $passed passed, $failed failed, $xfailed xfail, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
