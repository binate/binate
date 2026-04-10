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
    echo "Runs conformance tests against the specified backend mode."
    echo ""
    echo "Flags:"
    echo "  -v, --verbose   Show all test names (PASS, FAIL, XFAIL)"
    echo "  -q, --quiet     Show only failures and summary"
    echo "  (default)       Show failures in detail, passes as dots"
    echo ""
    echo "Filters select tests by substring match on the test name."
    echo "Multiple filters are OR'd: any match includes the test."
    echo ""
    echo "Examples:"
    echo "  $0 boot                   Run all tests via bootstrap interpreter"
    echo "  $0 boot-comp 040          Run test(s) matching '040' via compiler"
    echo "  $0 basic                  Run boot, boot-comp, boot-comp-int"
    echo "  $0 boot-comp slice nil    Run tests matching 'slice' or 'nil'"
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
    msd="$(cd "$(dirname "$0")/../scripts/modesets" && pwd)"
    for sf in "$msd"/*; do
        [ -f "$sf" ] || continue
        sname="$(basename "$sf")"
        modes="$(grep -v '^#' "$sf" | grep -v '^$' | tr '\n' ' ' | sed 's/ *$//')"
        printf "  %-20s %s\n" "$sname" "$modes"
    done
    echo ""
    echo "Test formats:"
    echo "  NNN_name.bn + .expected   Positive: run and compare stdout"
    echo "  NNN_name.bn + .error      Negative: must fail with matching error"
    echo "  NNN_name/ directory        Multi-package test (main.bn + pkg/)"
    echo ""
    echo "Xfail: NNN_name.xfail.<mode> marks a test as expected failure."
    echo ""
    echo "Environment:"
    echo "  BINATE_FLAGS              Extra flags for the compiler (e.g. \"-g\")"
    exit 1
fi
shift

# Expand mode sets — reads from scripts/modesets/ files
MODESETS_DIR="$(cd "$(dirname "$0")/../scripts/modesets" && pwd)"
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
        if [ "$VERBOSE" -eq 1 ]; then
            echo "PASS: $name"
        elif [ "$QUIET" -eq 0 ]; then
            printf "."
        fi
        passed=$((passed + 1))
    elif [ -f "$known_fail" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name (known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
    else
        if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
            echo ""
            echo "FAIL: $name"
            echo "  expected: $(head -3 "$expected")"
            echo "  actual:   $(echo "$actual" | head -3)"
        fi
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
    # Check that each line in the .error file matches as a regex in output
    all_found=true
    missing=""
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [ -z "$pattern" ] && continue
        if ! echo "$actual" | grep -qE "$pattern"; then
            all_found=false
            missing="$pattern"
            break
        fi
    done < "$errorfile"

    if $all_found; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "PASS: $name (error)"
        elif [ "$QUIET" -eq 0 ]; then
            printf "."
        fi
        passed=$((passed + 1))
    elif [ -f "$known_fail" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name (known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
    else
        if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
            echo ""
            echo "FAIL: $name (error)"
            echo "  missing: $missing"
            echo "  actual:  $(echo "$actual" | head -3)"
        fi
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

# Newline after dots in default mode
if [ "$VERBOSE" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    echo ""
fi
echo ""
echo "=== Summary ($MODE): $passed passed, $failed failed, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
