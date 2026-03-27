#!/bin/sh
# Usage: ./conformance/run.sh <mode> [filter...]
#
# Runs conformance tests against the specified backend.
# Optional filters select tests by substring match (e.g. "040" or "recursive").
#
# Modes:
#   bootstrap          Go bootstrap interpreter runs .bn files directly
#   selfhost           Bootstrap interprets main.bn, which runs .bn files
#   compiled           Bootstrap interprets compile.bn, which compiles .bn to native
#   compiled-interp    Self-compiled interpreter binary runs .bn files
#   compiled-compiler  Self-compiled compiler binary compiles .bn to native
#
# Test formats:
#   Single-file: NNN_name.bn + NNN_name.expected
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
    exit 1
fi
shift

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
    if [ ! -f "$expected" ]; then
        echo "SKIP: $name (no .expected file)"
        continue
    fi

    run_test "$name" "$bn" "$expected" ""
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
