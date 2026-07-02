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
CHECK_XPASS=0
SHARD_IDX=0
SHARD_COUNT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -q|--quiet)   QUIET=1; shift ;;
        --check-xpass) CHECK_XPASS=1; shift ;;
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
export VERBOSE QUIET CHECK_XPASS SHARD_IDX SHARD_COUNT

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
    echo "  --check-xpass   Run xfailed packages anyway; if one passes, fail"
    echo "                  the run (XPASS = stale xfail). Default skips them."
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
    echo "  $0 builder-comp vm               Run pkg/binate/vm tests via the builder"
    echo "  $0 basic                      Run builder-comp, builder-comp-int"
    echo "  $0 builder-comp,builder-comp-comp   Run all tests in two modes"
    echo "  $0 builder-comp ir codegen       Run pkg/binate/ir and pkg/binate/codegen tests"
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
    echo "  scripts/unittest/<pkg-path>.xfail.all marks it failing in EVERY"
    echo "  mode (one marker, not one per mode); a .xfail.<mode> overrides it."
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
        [ "$CHECK_XPASS" -eq 1 ] && flags="$flags --check-xpass"
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
# Search roots: collocated (pkg/, cmd/) and split-tree impls. Each impls/.../pkg/X
# path strips down to pkg/X as the package's logical name — the loader resolves
# an `import "pkg/X"` against any matching search root, so the canonical package
# name is the trailing pkg/... portion.
for testfile in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/impls" -name '*_test.bn' 2>/dev/null); do
    [ -f "$testfile" ] || continue
    dir="$(dirname "$testfile")"
    # Convert absolute path to package path:
    #   /path/to/binate/pkg/binate/ir                       -> pkg/binate/ir
    #   /path/to/binate/cmd/bnc                             -> cmd/bnc
    #   /path/to/binate/impls/core/common/pkg/builtins/lang -> pkg/builtins/lang
    #   /path/to/binate/impls/stdlib/pkg/std/strings        -> pkg/std/strings
    relpath="${dir#"$BINATE_DIR"/}"
    case "$relpath" in
        impls/*/pkg/*)
            # Strip everything up to the logical pkg/... name.  Handles both the
            # per-platform layout (impls/<tier>/<platform>/pkg/..., e.g.
            # impls/core/common) and the flattened layout (impls/<tier>/pkg/...,
            # e.g. impls/stdlib).
            pkg="pkg/${relpath#*/pkg/}"
            ;;
        *)
            pkg="$relpath"
            ;;
    esac
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
pkgskipped=0
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

    # Native-only packages are ALWAYS injected (native) in production — the
    # bytecode VM never interprets them.  Unit-testing one under an interpreter
    # mode lowers the package itself to bytecode, a configuration that never
    # ships (and that can't even run for a __c_call package, whose OP_C_CALL the
    # VM cannot lower: it would hit lower_instr's default arm — a hard abort —
    # since --test's typecheck does not set Checker.Interpreted).  The set:
    # pkg/std/* (the injected stdlib) plus pkg/builtins/rt (the runtime — native
    # substrate, uses __c_call for malloc/free/exit/…).  Skip them under the int
    # modes; the stdlib's cross-mode coverage is the conformance/stdlib suite
    # (run.sh under conformance/, where the stdlib is INJECTED), and rt's logic
    # is covered by its compiled-mode unit tests.  This is a by-design exclusion,
    # NOT a perf .skip-pkg nor a failure .xfail.
    case "$MODE" in
        *int*)
            case "$pkg" in
                pkg/std/*|pkg/builtins/rt)
                    if [ "$VERBOSE" -eq 1 ]; then
                        echo "SKIP-NATIVE-INT: $pkg (native-only, injected not interpreted)"
                    elif [ "$QUIET" -eq 0 ]; then
                        printf "s"
                    fi
                    pkgskipped=$((pkgskipped + 1))
                    continue
                    ;;
            esac
            ;;
    esac

    # Check for xfail.  is_xfail records that this package carries a marker so
    # the result handler can interpret pass/fail as XPASS/XFAIL.
    xfail_key="$(echo "$pkg" | tr '/' '-')"
    xfail_file="$SCRIPT_DIR/${xfail_key}.xfail.${MODE}"
    # A mode-independent <pkg>.xfail.all marks a package expected to fail in
    # EVERY mode — one marker instead of one per mode. A mode-specific
    # .xfail.<mode> takes precedence (more specific reason). ("all" = every
    # mode, not the scripts/modesets/all set, which omits native_x64_darwin.)
    [ -f "$xfail_file" ] || xfail_file="$SCRIPT_DIR/${xfail_key}.xfail.all"
    is_xfail=0
    if [ -f "$xfail_file" ]; then
        reason="$(cat "$xfail_file")"
        if [ "$CHECK_XPASS" -eq 0 ]; then
            # Default: skip the xfailed package without running it (it may
            # hang or be slow).
            if [ "$VERBOSE" -eq 1 ]; then
                echo "XFAIL: $pkg ($reason)"
            elif [ "$QUIET" -eq 0 ]; then
                printf "x"
            fi
            xfailed=$((xfailed + 1))
            continue
        fi
        # --check-xpass: run it anyway so a now-passing package surfaces as an
        # XPASS (stale marker) below.
        is_xfail=1
    fi

    # Whole-package skip file: <pkg-key>.skip-pkg.<mode>.  Distinct from
    # .xfail (which asserts the package FAILS — skipped by default, but run
    # under --check-xpass, which XPASS-errors if it now passes) and from
    # .skip (which drops individual tests but still runs the package):
    # .skip-pkg omits the whole package from this mode
    # because it is too slow to run here (a pathological double-VM blowup
    # that times out the shard).  It is NOT a failure — the tests pass,
    # they're just not run in this lane — and it is tracked for re-adding
    # once the package is optimized.  Contents are a one-line reason.
    skippkg_file="$SCRIPT_DIR/${xfail_key}.skip-pkg.${MODE}"
    if [ -f "$skippkg_file" ]; then
        reason="$(cat "$skippkg_file")"
        if [ "$VERBOSE" -eq 1 ]; then
            echo "SKIP-PKG: $pkg ($reason)"
        elif [ "$QUIET" -eq 0 ]; then
            printf "s"
        fi
        pkgskipped=$((pkgskipped + 1))
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
        if [ "$is_xfail" -eq 1 ]; then
            # --check-xpass: an xfailed package passed — stale marker.
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "XPASS: $pkg [${elapsed}s] (passed despite xfail marker — stale xfail?)"
            fi
            failed=$((failed + 1))
            failures="$failures $pkg(XPASS)"
        else
            count=$(echo "$output" | grep -o '[0-9]* passed' | head -1)
            if [ "$VERBOSE" -eq 1 ]; then
                echo "PASS: $pkg ($count) [${elapsed}s]"
            elif [ "$QUIET" -eq 0 ]; then
                printf "."
            fi
            passed=$((passed + 1))
        fi
    else
        if [ "$is_xfail" -eq 1 ]; then
            # --check-xpass: an xfailed package failed as expected.
            if [ "$VERBOSE" -eq 1 ]; then
                echo "XFAIL: $pkg ($reason) [${elapsed}s]"
            elif [ "$QUIET" -eq 0 ]; then
                printf "x"
            fi
            xfailed=$((xfailed + 1))
        else
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "FAIL: $pkg [${elapsed}s]"
                echo "$output" | sed 's/^/  /'
            fi
            failed=$((failed + 1))
            failures="$failures $pkg"
        fi
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
echo "=== Summary ($MODE)$shard_suffix: $passed passed, $failed failed, $xfailed xfail, $skipped skipped, $pkgskipped pkg-skipped ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
