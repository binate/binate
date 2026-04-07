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

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 <mode> [filter...]"
    echo ""
    echo "Modes:"
    for r in "$(dirname "$0")"/runners/*.sh; do
        [ -f "$r" ] || continue
        rname="$(basename "$r" .sh)"
        desc=$(grep '^# Runner:' "$r" | head -1 | sed 's/^# Runner: //')
        printf "  %-20s %s\n" "$rname" "$desc"
    done
    echo ""
    echo "Mode sets:"
    echo "  basic                boot, boot-comp, boot-comp-int"
    echo "  all                  basic + boot-comp-comp"
    echo "  full                 all + boot-comp-comp-comp"
    exit 1
fi
shift

# Expand mode sets into multiple sequential runs
expand_set() {
    case "$1" in
        basic) echo "boot boot-comp boot-comp-int" ;;
        all)   echo "boot boot-comp boot-comp-int boot-comp-comp boot-comp-comp-comp" ;;
        # TODO: add boot-comp-int-int back once flat memory path doesn't depend on compiled-only pkg/rt
        full)  echo "boot boot-comp boot-comp-int boot-comp-comp boot-comp-comp-int boot-comp-comp-comp" ;;
        *)     return 1 ;;
    esac
}

MODES="$(expand_set "$MODE" 2>/dev/null)" && {
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
        echo "XFAIL: $pkg ($reason)"
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
        # Extract test count from output
        count=$(echo "$output" | grep -o '[0-9]* passed' | head -1)
        echo "PASS: $pkg ($count) [${elapsed}s]"
        passed=$((passed + 1))
    else
        echo "FAIL: $pkg [${elapsed}s]"
        echo "$output" | sed 's/^/  /' | tail -5
        failed=$((failed + 1))
        failures="$failures $pkg"
    fi
done

echo ""
echo "=== Summary ($MODE): $passed passed, $failed failed, $xfailed xfail, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
