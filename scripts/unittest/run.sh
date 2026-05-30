#!/bin/sh
# Usage: ./scripts/unittest/run.sh <mode> [filter...]
#
# Runs unit tests for all packages (or filtered packages) using the specified
# backend mode.
#
# Modes (chains of: builder=resolved BUILDER_VERSION binary running
# cmd/bnc, comp=compiler from current tree, int=bytecode VM).  The
# first link is the BUILDER_VERSION-resolved binary (currently
# bootstrap-* via scripts/fetch-builder.sh, eventually a tagged
# bnc-X.Y.Z bundle).
#
#   builder-comp             Builder interprets bnc, which compiles and runs tests
#   builder-comp-int         Compiled bni runs --test natively via bytecode VM
#   builder-comp-comp        Self-compiled compiler (gen1) runs --test
#   builder-comp-comp-int    Gen1-compiled bni runs --test natively via bytecode VM
#   builder-comp-comp-comp   Gen2 compiler runs --test
#
# Mode sets:
#   basic               builder-comp, builder-comp-int
#   all                 basic + builder-comp-comp, builder-comp-comp-int, builder-comp-comp-comp
#
# Filters select packages by substring match (e.g. "ir" matches "pkg/binate/ir").
#
# Per-package xfail:
#   scripts/unittest/<pkg-with-slashes-replaced-by-dashes>.xfail.<mode>
#   e.g. scripts/unittest/pkg-vm.xfail.builder-comp-comp-int
#   Contents are the reason for the expected failure.
#
# Per-test skip (bni-based runners only):
#   scripts/unittest/<pkg-with-slashes-replaced-by-dashes>.skip.<mode>
#   e.g. scripts/unittest/pkg-codegen.skip.builder-comp-int-int
#   Contents are a name substring; matching Test* functions are
#   skipped via `--skip` to the runner.

# Parse flags
VERBOSE=0
QUIET=0
SHARD_IDX=0
SHARD_COUNT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        --shard)
            # Expect `i/n` (1-based shard index out of count).
            if [ -z "$2" ]; then
                echo "--shard requires an argument of the form i/n" >&2
                exit 2
            fi
            case "$2" in
                */*) ;;
                *)   echo "--shard argument must be i/n, got: $2" >&2
                     exit 2 ;;
            esac
            SHARD_IDX="${2%%/*}"
            SHARD_COUNT="${2##*/}"
            case "$SHARD_IDX" in
                ''|*[!0-9]*) echo "shard index must be a positive integer" >&2
                             exit 2 ;;
            esac
            case "$SHARD_COUNT" in
                ''|*[!0-9]*) echo "shard count must be a positive integer" >&2
                             exit 2 ;;
            esac
            if [ "$SHARD_COUNT" -lt 1 ] || [ "$SHARD_IDX" -lt 1 ] ||
                    [ "$SHARD_IDX" -gt "$SHARD_COUNT" ]; then
                echo "--shard $2: index must be in [1, count]" >&2
                exit 2
            fi
            shift 2 ;;
        *)            break ;;
    esac
done
export VERBOSE QUIET SHARD_IDX SHARD_COUNT

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 [-v|-q] [--shard i/n] <mode> [filter...]"
    echo ""
    echo "Runs unit tests for all packages (or filtered packages) using"
    echo "the specified backend mode."
    echo ""
    echo "Flags:"
    echo "  -v, --verbose   Show per-test PASS/FAIL output"
    echo "  -q, --quiet     Show only failures and summary"
    echo "  --shard i/n     Run only this shard's packages (1-based: shard"
    echo "                  i of n, by 0-based position in the discovered"
    echo "                  package list modulo n)"
    echo "  (default)       Show pass/fail per package, failures in detail"
    echo ""
    echo "Filters select packages by substring match (e.g. 'ir' matches"
    echo "'pkg/binate/ir'). Multiple filters are OR'd."
    echo ""
    echo "Examples:"
    echo "  $0 builder-comp                  Run all tests via the builder"
    echo "  $0 builder-comp vm               Run pkg/vm tests via the builder"
    echo "  $0 basic                      Run builder-comp, builder-comp-int"
    echo "  $0 builder-comp,builder-comp-comp   Run all tests in two modes"
    echo "  $0 builder-comp ir codegen       Run pkg/binate/ir and pkg/codegen tests"
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
    echo "  e.g. scripts/unittest/pkg-vm.xfail.builder-comp-comp-int"
    echo "  (slashes in package path replaced with dashes)"
    echo ""
    echo "Per-test skip: scripts/unittest/<pkg-path>.skip.<mode>"
    echo "  Contents are a name substring; matching Test*"
    echo "  functions are skipped (passed as --skip to the"
    echo "  runner).  Honored by bni-based runners (builder-comp-int,"
    echo "  builder-comp-int-int, builder-comp-comp-int)."
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

# Try mode set file first, then comma-separated list
MODES="$(expand_set "$MODE" 2>/dev/null)" || {
    case "$MODE" in
        *,*) MODES="$(echo "$MODE" | tr ',' ' ')" ;;
    esac
}

[ -n "$MODES" ] && {
    overall_exit=0
    for m in $MODES; do
        echo "========================================"
        echo "=== Mode: $m"
        echo "========================================"
        flags=""
        [ "$VERBOSE" -eq 1 ] && flags="-v"
        [ "$QUIET" -eq 1 ] && flags="-q"
        [ "$SHARD_COUNT" -gt 0 ] && \
            flags="$flags --shard $SHARD_IDX/$SHARD_COUNT"
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
    # Convert absolute path to package path (e.g. /path/to/binate/pkg/binate/ir -> pkg/binate/ir)
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

# Counter for the shard's modulo selection.  Incremented for every
# package that survives the substring filter (i.e. would have been
# run absent the --shard flag), so the same shard config produces a
# stable subset regardless of which filters are active.
shard_pos=0

for pkg in $PACKAGES; do
    # Apply filters (substring match on package path)
    if [ $# -gt 0 ]; then
        match=0
        for f in "$@"; do
            case "$pkg" in *"$f"*) match=1; break;; esac
        done
        if [ "$match" -eq 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Apply shard selection (1-based: shard i of n keeps positions
    # where shard_pos % n == i - 1).  Packages skipped by sharding
    # are NOT counted in `skipped` — they're being handled by some
    # other shard's invocation.
    if [ "$SHARD_COUNT" -gt 0 ]; then
        if [ $((shard_pos % SHARD_COUNT)) -ne $((SHARD_IDX - 1)) ]; then
            shard_pos=$((shard_pos + 1))
            continue
        fi
    fi
    shard_pos=$((shard_pos + 1))

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

    # Per-test skip file: <pkg-key>.skip.<mode>.  Contents are a
    # substring pattern; tests whose name contains the pattern are
    # skipped (passed as --skip to the runner).  Only the bni-based
    # runners (builder-comp-int, builder-comp-int-int, builder-comp-comp-int)
    # honor this; other modes ignore SKIP_FILTER.
    skip_file="$SCRIPT_DIR/${xfail_key}.skip.${MODE}"
    SKIP_FILTER=""
    if [ -f "$skip_file" ]; then
        SKIP_FILTER="$(cat "$skip_file")"
    fi
    export SKIP_FILTER

    # Run tests with timing
    start_time=$(date +%s)
    if [ "$VERBOSE" -eq 1 ]; then echo "STARTING: $pkg"; fi
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
            echo "$output" | sed 's/^/  /'
        fi
        failed=$((failed + 1))
        failures="$failures $pkg"
    fi
done

if [ "$VERBOSE" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    echo ""
fi
echo ""
shard_suffix=""
if [ "$SHARD_COUNT" -gt 0 ]; then
    shard_suffix=" (shard $SHARD_IDX/$SHARD_COUNT)"
fi
echo "=== Summary ($MODE)$shard_suffix: $passed passed, $failed failed, $xfailed xfail, $skipped skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
