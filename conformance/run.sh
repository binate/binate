#!/bin/sh
# Usage: ./conformance/run.sh <mode> [filter...]
#
# Runs conformance tests against the specified backend.
# Optional filters select tests by substring match (e.g. "040" or "recursive").
#
# Environment:
#   BINATE_FLAGS    Extra flags passed to the Binate compiler (e.g. "-g" for debug info)
#
# Modes (chains of: boot=bootstrap, int=interpreter, comp=compiler):
#   boot                Go bootstrap interpreter runs .bn directly
#   boot-int            boot interprets cmd/bni, which interprets .bn
#   boot-comp           boot interprets cmd/bnc, which compiles .bn to native
#   boot-comp-int       boot-comp compiles cmd/bni → binary, binary interprets .bn
#   boot-comp-int-int   boot-comp-int interprets cmd/bni, which interprets .bn
#   boot-comp-comp      boot-comp compiles cmd/bnc → gen1, gen1 compiles .bn
#   boot-comp-comp-comp boot-comp-comp builds gen1, gen1 → gen2, gen2 compiles .bn
#
# Test formats:
#   Single-file: NNN_name.bn + NNN_name.expected (positive: run and compare output)
#   Single-file: NNN_name.bn + NNN_name.error    (negative: must fail, output contains error strings)
#   Multi-package: NNN_name/ directory with main.bn, expected, and pkg/ subdirectory

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
    echo "  basic                boot, boot-int, boot-comp"
    echo "  all                  all modes"
    exit 1
fi
shift

# Expand mode sets into multiple sequential runs
expand_set() {
    case "$1" in
        basic) echo "boot boot-int boot-comp" ;;
        all)   echo "boot boot-int boot-comp boot-comp-int boot-comp-int-int boot-comp-comp boot-comp-comp-comp" ;;
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
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
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

# Run setup (build step for compiled modes)
runner_setup

# Ensure cleanup runs on exit
trap 'runner_cleanup' EXIT

passed=0
failed=0
skipped=0
failures=""

run_test() {
    name="$1"
    bn="$2"         # path to .bn file (single-file) or main.bn (multi-pkg)
    expected="$3"    # path to expected output file
    root="$4"        # root dir for multi-pkg (empty for single-file)

    actual=$(runner_exec "$bn" "$root")

    expected_content="$(cat "$expected")"
    known_fail="$SCRIPT_DIR/${name}.xfail.${MODE}"
    if [ "$actual" = "$expected_content" ]; then
        echo "PASS: $name"
        passed=$((passed + 1))
    elif [ -f "$known_fail" ]; then
        echo "XFAIL: $name (known failure: $(cat "$known_fail"))"
        skipped=$((skipped + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $(head -3 "$expected")"
        echo "  actual:   $(echo "$actual" | head -3)"
        failed=$((failed + 1))
        failures="$failures $name"
    fi
}

run_error_test() {
    name="$1"
    bn="$2"         # path to .bn file
    errorfile="$3"  # path to .error file (each line is a required substring)
    root="$4"       # root dir for multi-pkg (empty for single-file)

    actual=$(runner_exec "$bn" "$root")
    rc=$?

    known_fail="$SCRIPT_DIR/${name}.xfail.${MODE}"

    # The program should have failed (non-zero exit or error output)
    # Check that each line in the .error file appears as a substring in output
    all_found=true
    missing=""
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [ -z "$pattern" ] && continue
        case "$actual" in
            *"$pattern"*) ;;
            *) all_found=false; missing="$pattern"; break ;;
        esac
    done < "$errorfile"

    if $all_found; then
        echo "PASS: $name (error)"
        passed=$((passed + 1))
    elif [ -f "$known_fail" ]; then
        echo "XFAIL: $name (known failure: $(cat "$known_fail"))"
        skipped=$((skipped + 1))
    else
        echo "FAIL: $name (error)"
        echo "  missing: $missing"
        echo "  actual:  $(echo "$actual" | head -3)"
        failed=$((failed + 1))
        failures="$failures $name"
    fi
}

# Single-file tests: NNN_name.bn
for bn in "$SCRIPT_DIR"/*.bn; do
    [ -f "$bn" ] || continue
    name="$(basename "$bn" .bn)"

    # Apply filters
    if [ $# -gt 0 ]; then
        match=0
        for f in "$@"; do
            case "$name" in *"$f"*) match=1; break;; esac
        done
        if [ "$match" -eq 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi
    expected="$SCRIPT_DIR/${name}.expected"
    errorfile="$SCRIPT_DIR/${name}.error"
    if [ -f "$errorfile" ]; then
        run_error_test "$name" "$bn" "$errorfile" ""
    elif [ -f "$expected" ]; then
        run_test "$name" "$bn" "$expected" ""
    else
        echo "SKIP: $name (no .expected or .error file)"
        continue
    fi
done

# Multi-package tests: NNN_name/ directories
for dir in "$SCRIPT_DIR"/[0-9][0-9][0-9]_*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"

    # Apply filters
    if [ $# -gt 0 ]; then
        match=0
        for f in "$@"; do
            case "$name" in *"$f"*) match=1; break;; esac
        done
        if [ "$match" -eq 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi

    main_bn="$dir/main.bn"
    expected="$dir/expected"
    if [ ! -f "$main_bn" ]; then
        echo "SKIP: $name (no main.bn)"
        continue
    fi
    if [ ! -f "$expected" ]; then
        echo "SKIP: $name (no expected file)"
        continue
    fi

    run_test "$name" "$main_bn" "$expected" "$dir"
done

echo ""
echo "=== Summary: $passed passed, $failed failed, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
