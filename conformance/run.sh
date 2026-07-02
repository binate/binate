#!/bin/sh
# Usage: ./conformance/run.sh <mode> [filter...]
#
# Runs conformance tests against the specified backend.
# Optional filters select tests by substring match (e.g. "040" or "recursive").
#
# Environment:
#   BINATE_FLAGS    Extra flags passed to the Binate compiler (e.g. "-g" for debug info)
#
# Modes (chains of: builder=resolved BUILDER_VERSION binary,
# comp=compiler from current tree, int=bytecode VM).  The first
# link is the BUILDER_VERSION-resolved binary (currently bootstrap-*
# via scripts/fetch-builder.sh, eventually a tagged bnc-X.Y.Z
# bundle).
#
#   builder-comp             Builder interprets cmd/bnc, which compiles .bn to native
#   builder-comp-int         builder-comp compiles cmd/bni → binary, binary runs .bn via bytecode VM
#   builder-comp-int-int     builder-comp-int interprets cmd/bni, which interprets .bn
#   builder-comp-comp        builder-comp compiles cmd/bnc → gen1, gen1 compiles .bn
#   builder-comp-comp-int    gen1 compiles cmd/bni → binary, binary runs .bn via bytecode VM
#   builder-comp-comp-comp   builder-comp-comp builds gen1, gen1 → gen2, gen2 compiles .bn
#
# Test formats:
#   Single-file: NNN_name.bn + NNN_name.expected (positive: run and compare output)
#   Single-file: NNN_name.bn + NNN_name.error    (negative: must fail, output contains error strings)
#   Multi-package: NNN_name/ directory with main.bn, expected, and pkg/ subdirectory
#
# Per-mode overrides:
#   NNN_name.expected.<mode> / NNN_name.error.<mode> (single-file) or
#   <dir>/expected.<mode> / <dir>/error.<mode> (multi-package) — used in
#   preference to the generic file when the current MODE matches.
#   Lets a target-specific output (e.g. ILP32 sizeof) override the
#   canonical LP64 .expected without rewriting the .bn.

# Parse flags
VERBOSE=0
QUIET=0
CHECK_XPASS=0
EXACT=0
while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose)     VERBOSE=1; shift ;;
        -q|--quiet)       QUIET=1; shift ;;
        --check-xpass)    CHECK_XPASS=1; shift ;;
        --exact)          EXACT=1; shift ;;
        *)                break ;;
    esac
done
export VERBOSE QUIET CHECK_XPASS EXACT

# filter_match NAME FILTER... — return 0 if NAME passes the filter set.
# Substring match (NAME contains FILTER) by default; exact (NAME = FILTER)
# under --exact.  Exact is for callers that pass full test names and must NOT
# pull in longer siblings — e.g. `value-struct` substring-matching
# `value-struct-large`, which would run an unintended (possibly unmarked) test.
filter_match() {
    local name="$1"
    shift
    local f
    for f in "$@"; do
        if [ "$EXACT" -eq 1 ]; then
            [ "$name" = "$f" ] && return 0
        else
            case "$name" in *"$f"*) return 0 ;; esac
        fi
    done
    return 1
}

MODE="$1"
if [ -z "$MODE" ]; then
    echo "Usage: $0 [-v|-q] <mode> [filter...]"
    echo ""
    echo "Runs conformance tests against the specified backend mode."
    echo ""
    echo "Flags:"
    echo "  -v, --verbose   Show all test names (PASS, FAIL, XFAIL)"
    echo "  -q, --quiet     Show only failures and summary"
    echo "  --check-xpass   Run xfailed tests anyway; if any passes, fail"
    echo "                  the run (XPASS). Default is to skip xfailed tests"
    echo "                  without running them (they may hang or be slow)."
    echo "  --exact         Match filters by exact test name, not substring"
    echo "                  (so 'value-struct' does not also pull in"
    echo "                  'value-struct-large')."
    echo "  (default)       Show failures in detail, passes as dots"
    echo ""
    echo "Filters select tests by substring match on the test name"
    echo "(exact match under --exact)."
    echo "Multiple filters are OR'd: any match includes the test."
    echo ""
    echo "Examples:"
    echo "  $0 builder-comp                  Run all tests via the builder"
    echo "  $0 builder-comp 040              Run test(s) matching '040'"
    echo "  $0 basic                      Run builder-comp, builder-comp-int"
    echo "  $0 builder-comp,builder-comp-comp   Run all tests in two modes"
    echo "  $0 builder-comp slice nil        Run tests matching 'slice' or 'nil'"
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
    echo "       NNN_name.xfail.all marks it failing in EVERY mode (one"
    echo "       marker, not one per mode); a .xfail.<mode> overrides it."
    echo "Per-mode .expected / .error: NNN_name.{expected,error}.<mode>"
    echo "                             overrides the generic file for that mode"
    echo "                             (e.g. LP64-vs-ILP32 size output)."
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

# strip_signal_msgs filters out-of-band signal-death diagnostics
# from a captured runner output stream so silent-SEGV tests
# (e.g. 385_iface_nil_dispatch) get the same `actual` across
# macOS dev and Linux CI.  Function lives in a shared lib so
# the hygiene smoke can test it independently.
. "$(dirname "$0")/../scripts/lib/strip-signal-msgs.sh"

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
        [ "$VERBOSE" -eq 1 ] && flags="$flags -v"
        [ "$QUIET" -eq 1 ] && flags="$flags -q"
        [ "$CHECK_XPASS" -eq 1 ] && flags="$flags --check-xpass"
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

# Host CPU arch in Binate's naming (matches `#[build(is(arch, ...))]` tokens).
# Used as an `expected.<arch>` resolution tier for tests whose output tracks
# the build's arch on NON-cross modes (where target == host) — e.g. a test
# printing the selected arch passes on both an aarch64 dev box and an x64 CI
# runner. Cross-compile modes pin the target via `expected.<MODE>` (higher
# precedence), so this tier never overrides them.
# Honor a pre-set HOST_ARCH (lets a developer cross-check another arch's
# expected.<arch> resolution without that hardware); otherwise derive it.
if [ -z "$HOST_ARCH" ]; then
    case "$(uname -m)" in
        arm64|aarch64) HOST_ARCH=aarch64 ;;
        x86_64|amd64)  HOST_ARCH=x64 ;;
        armv7*|armv6*|arm) HOST_ARCH=arm32 ;;
        *) HOST_ARCH=unknown ;;
    esac
fi
export HOST_ARCH

# Host OS in Binate's naming (matches `#[build(is(os, ...))]` tokens / build.OS).
# Same role as HOST_ARCH but for tests whose output tracks the build's OS on
# non-cross modes (e.g. one printing os=darwin / os=linux). Honors a pre-set
# value for cross-checking another OS's expected.<os> resolution.
if [ -z "$HOST_OS" ]; then
    case "$(uname -s)" in
        Darwin) HOST_OS=darwin ;;
        Linux)  HOST_OS=linux ;;
        *) HOST_OS=unknown ;;
    esac
fi
export HOST_OS

# OVERRIDE_MODE: a native-arm32 mode shares the exact ILP32 layout and the
# baremetal/linux environment of its LLVM sibling
# (builder-comp_native_arm32_baremetal -> builder-comp_arm32_baremetal), so it
# inherits that sibling's per-mode .expected / .error / .xfail overrides when it
# has no native-specific one of its own.  Without this the native mode ignores
# the sibling's ILP32 .expected overrides (e.g. an ILP32 sizeof / -2^31 output)
# and its xfails (e.g. libc-on-baremetal tests), producing false failures.
# Empty for every other mode, where the OVERRIDE_MODE tiers below are no-ops.
OVERRIDE_MODE=""
case "$MODE" in
    *_native_arm32_*) OVERRIDE_MODE=$(printf '%s' "$MODE" | sed 's/_native_arm32_/_arm32_/') ;;
esac

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
suite_start=$(date +%s)

run_test() {
    name="$1"
    bn="$2"         # path to .bn file (single-file) or main.bn (multi-pkg)
    expected="$3"    # path to expected output file
    root="$4"        # root dir for multi-pkg (empty for single-file)

    known_fail="$SCRIPT_DIR/${name}.xfail.${MODE}"
    if [ ! -f "$known_fail" ] && [ -n "$OVERRIDE_MODE" ]; then
        known_fail="$SCRIPT_DIR/${name}.xfail.${OVERRIDE_MODE}"
    fi
    # A mode-independent ${name}.xfail.all marks a test expected to fail in
    # EVERY mode (e.g. a backend-independent front-end gap) — one marker
    # instead of one per mode. A mode-specific .xfail.<mode> takes precedence
    # (its reason text is more specific). NB: "all" here means every mode, not
    # the scripts/modesets/all set (which omits native_x64_darwin).
    [ -f "$known_fail" ] || known_fail="$SCRIPT_DIR/${name}.xfail.all"

    # Default: skip xfailed tests without running them — they may hang
    # or be very slow. With --check-xpass, run them anyway so we can
    # detect stale xfails (tests that pass despite the xfail marker).
    if [ -f "$known_fail" ] && [ "$CHECK_XPASS" -eq 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name (skipped; known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
        return
    fi

    t_start=$(date +%s)
    actual=$(runner_exec "$bn" "$root")
    actual=$(strip_signal_msgs "$actual")
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

    expected_content="$(cat "$expected")"
    if [ "$actual" = "$expected_content" ]; then
        if [ -f "$known_fail" ]; then
            # XPASS: xfail marker exists but the test passes — stale xfail.
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "XPASS: $name [${elapsed}s] (passed despite xfail marker — stale xfail?)"
            fi
            failed=$((failed + 1))
            failures="$failures $name(XPASS)"
        else
            if [ "$VERBOSE" -eq 1 ]; then
                echo "PASS: $name [${elapsed}s]"
            elif [ "$QUIET" -eq 0 ]; then
                printf "."
            fi
            passed=$((passed + 1))
        fi
    elif [ -f "$known_fail" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name [${elapsed}s] (known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
    else
        if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
            echo ""
            echo "FAIL: $name [${elapsed}s]"
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

    known_fail="$SCRIPT_DIR/${name}.xfail.${MODE}"
    if [ ! -f "$known_fail" ] && [ -n "$OVERRIDE_MODE" ]; then
        known_fail="$SCRIPT_DIR/${name}.xfail.${OVERRIDE_MODE}"
    fi
    [ -f "$known_fail" ] || known_fail="$SCRIPT_DIR/${name}.xfail.all"  # see run_test

    # Default: skip xfailed tests without running them. See run_test.
    if [ -f "$known_fail" ] && [ "$CHECK_XPASS" -eq 0 ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name (skipped; known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
        return
    fi

    t_start=$(date +%s)
    actual=$(runner_exec "$bn" "$root")
    rc=$?
    actual=$(strip_signal_msgs "$actual")
    t_end=$(date +%s)
    elapsed=$((t_end - t_start))

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
        if [ -f "$known_fail" ]; then
            # XPASS: xfail marker exists but test passes — stale xfail.
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "XPASS: $name [${elapsed}s] (passed despite xfail marker — stale xfail?)"
            fi
            failed=$((failed + 1))
            failures="$failures $name(XPASS)"
        else
            if [ "$VERBOSE" -eq 1 ]; then
                echo "PASS: $name (error) [${elapsed}s]"
            elif [ "$QUIET" -eq 0 ]; then
                printf "."
            fi
            passed=$((passed + 1))
        fi
    elif [ -f "$known_fail" ]; then
        if [ "$VERBOSE" -eq 1 ]; then
            echo "XFAIL: $name [${elapsed}s] (known failure: $(cat "$known_fail"))"
        elif [ "$QUIET" -eq 0 ]; then
            printf "x"
        fi
        skipped=$((skipped + 1))
    else
        if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
            echo ""
            echo "FAIL: $name (error) [${elapsed}s]"
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
    if [ $# -gt 0 ] && ! filter_match "$name" "$@"; then
        skipped=$((skipped + 1))
        continue
    fi
    expected="$SCRIPT_DIR/${name}.expected"
    errorfile="$SCRIPT_DIR/${name}.error"
    # Per-mode overrides: NNN_name.{expected,error}.<MODE> takes
    # precedence over the generic NNN_name.{expected,error} when
    # present.  Used for tests whose canonical .expected is target-
    # specific (e.g. LP64-pinned sizeof output on arm32 ILP32).  Host-arch and
    # host-os tiers (NNN_name.expected.<arch> / .<os>) sit below the per-mode
    # override for tests whose output tracks the build's arch/OS on non-cross
    # modes (target == host).
    if [ -f "$SCRIPT_DIR/${name}.expected.${HOST_ARCH}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${HOST_ARCH}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.expected.${HOST_OS}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${HOST_OS}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$SCRIPT_DIR/${name}.expected.${OVERRIDE_MODE}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${OVERRIDE_MODE}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.expected.${MODE}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${MODE}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$SCRIPT_DIR/${name}.error.${OVERRIDE_MODE}" ]; then
        errorfile="$SCRIPT_DIR/${name}.error.${OVERRIDE_MODE}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.error.${MODE}" ]; then
        errorfile="$SCRIPT_DIR/${name}.error.${MODE}"
    fi
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
    if [ $# -gt 0 ] && ! filter_match "$name" "$@"; then
        skipped=$((skipped + 1))
        continue
    fi

    main_bn="$dir/main.bn"
    expected="$dir/expected"
    errorfile="$dir/error"
    # Host-arch/host-os tiers then per-mode override (mode wins):
    # $dir/expected.<arch> / .<os> cover NON-cross modes (target==host) where
    # output tracks the build's arch/OS; $dir/expected.<MODE> pins cross modes.
    if [ -f "$dir/expected.${HOST_ARCH}" ]; then
        expected="$dir/expected.${HOST_ARCH}"
    fi
    if [ -f "$dir/expected.${HOST_OS}" ]; then
        expected="$dir/expected.${HOST_OS}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$dir/expected.${OVERRIDE_MODE}" ]; then
        expected="$dir/expected.${OVERRIDE_MODE}"
    fi
    if [ -f "$dir/expected.${MODE}" ]; then
        expected="$dir/expected.${MODE}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$dir/error.${OVERRIDE_MODE}" ]; then
        errorfile="$dir/error.${OVERRIDE_MODE}"
    fi
    if [ -f "$dir/error.${MODE}" ]; then
        errorfile="$dir/error.${MODE}"
    fi
    if [ ! -f "$main_bn" ]; then
        echo "SKIP: $name (no main.bn)"
        continue
    fi
    if [ -f "$errorfile" ]; then
        run_error_test "$name" "$main_bn" "$errorfile" "$dir"
    elif [ -f "$expected" ]; then
        run_test "$name" "$main_bn" "$expected" "$dir"
    else
        echo "SKIP: $name (no expected or error file)"
        continue
    fi
done

# Nested single-file tests: *.bn under designated subtrees
# (conformance/matrix/, conformance/regressions/, conformance/spec/),
# identified by their path RELATIVE to conformance/ — a stable,
# collision-free name with no test number, so concurrent additions never
# collide and nothing ever needs renumbering. See conformance/matrix/README.md.
# Discovery and run mirror the flat single-file loop above; the only
# differences are the recursive find and the relative-path name, which makes
# ${name}.expected and ${name}.xfail.${MODE} resolve to the cell's own
# siblings. (Paths must not contain spaces — they are word-split here.)
#
# conformance/spec/ holds the rule-ID-cited spec-conformance tests
# (plan-spec-tests.md); like matrix/ and regressions/ it runs in the default
# suite, and thus in the conformance CI matrix.
#
# A nested directory holding a main.bn is a multi-package test (same form as the
# top-level NNN_name/ tests) — those are run by the loop further below; their
# .bn files (main.bn + the pkg/ subtree) are excluded here via in_multipkg.

# in_multipkg: true if a .bn belongs to a multi-package test — it is a main.bn,
# or some ancestor directory (below conformance/) holds a main.bn.
in_multipkg() {
    case "$1" in */main.bn) return 0 ;; esac
    _d=$(dirname "$1")
    while [ "$_d" != "$SCRIPT_DIR" ] && [ "$_d" != "/" ] && [ -n "$_d" ]; do
        [ -f "$_d/main.bn" ] && return 0
        _d=$(dirname "$_d")
    done
    return 1
}

for bn in $(find "$SCRIPT_DIR/matrix" "$SCRIPT_DIR/regressions" "$SCRIPT_DIR/spec" "$SCRIPT_DIR/stdlib" -name '*.bn' 2>/dev/null | sort); do
    [ -f "$bn" ] || continue
    in_multipkg "$bn" && continue   # part of a multi-package test (handled below)
    name="${bn#"$SCRIPT_DIR"/}"
    name="${name%.bn}"

    # Apply filters
    if [ $# -gt 0 ] && ! filter_match "$name" "$@"; then
        skipped=$((skipped + 1))
        continue
    fi
    expected="$SCRIPT_DIR/${name}.expected"
    errorfile="$SCRIPT_DIR/${name}.error"
    if [ -f "$SCRIPT_DIR/${name}.expected.${HOST_ARCH}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${HOST_ARCH}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.expected.${HOST_OS}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${HOST_OS}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$SCRIPT_DIR/${name}.expected.${OVERRIDE_MODE}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${OVERRIDE_MODE}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.expected.${MODE}" ]; then
        expected="$SCRIPT_DIR/${name}.expected.${MODE}"
    fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$SCRIPT_DIR/${name}.error.${OVERRIDE_MODE}" ]; then
        errorfile="$SCRIPT_DIR/${name}.error.${OVERRIDE_MODE}"
    fi
    if [ -f "$SCRIPT_DIR/${name}.error.${MODE}" ]; then
        errorfile="$SCRIPT_DIR/${name}.error.${MODE}"
    fi
    if [ -f "$errorfile" ]; then
        run_error_test "$name" "$bn" "$errorfile" ""
    elif [ -f "$expected" ]; then
        run_test "$name" "$bn" "$expected" ""
    else
        echo "SKIP: $name (no .expected or .error file)"
    fi
done

# Nested multi-package tests: a directory under the designated subtrees holding
# a main.bn (same form as the top-level NNN_name/ multi-package tests, but with
# the relative-path name). Lets conformance/spec/ chapters carry multi-package
# tests — most pkg.* rules (and the import-scoping defects) need >=2 packages.
# Per-mode expected/error/xfail markers are siblings of the directory, exactly
# as for the relative-path single-file tests above.
for main_bn in $(find "$SCRIPT_DIR/matrix" "$SCRIPT_DIR/regressions" "$SCRIPT_DIR/spec" "$SCRIPT_DIR/stdlib" -name main.bn 2>/dev/null | sort); do
    [ -f "$main_bn" ] || continue
    dir="$(dirname "$main_bn")"
    name="${dir#"$SCRIPT_DIR"/}"

    if [ $# -gt 0 ] && ! filter_match "$name" "$@"; then
        skipped=$((skipped + 1))
        continue
    fi
    expected="$dir/expected"
    errorfile="$dir/error"
    if [ -f "$dir/expected.${HOST_ARCH}" ]; then expected="$dir/expected.${HOST_ARCH}"; fi
    if [ -f "$dir/expected.${HOST_OS}" ]; then expected="$dir/expected.${HOST_OS}"; fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$dir/expected.${OVERRIDE_MODE}" ]; then expected="$dir/expected.${OVERRIDE_MODE}"; fi
    if [ -f "$dir/expected.${MODE}" ]; then expected="$dir/expected.${MODE}"; fi
    if [ -n "$OVERRIDE_MODE" ] && [ -f "$dir/error.${OVERRIDE_MODE}" ]; then errorfile="$dir/error.${OVERRIDE_MODE}"; fi
    if [ -f "$dir/error.${MODE}" ]; then errorfile="$dir/error.${MODE}"; fi
    if [ -f "$errorfile" ]; then
        run_error_test "$name" "$main_bn" "$errorfile" "$dir"
    elif [ -f "$expected" ]; then
        run_test "$name" "$main_bn" "$expected" "$dir"
    else
        echo "SKIP: $name (no expected or error file)"
    fi
done

# Newline after dots in default mode
if [ "$VERBOSE" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    echo ""
fi
echo ""
suite_end=$(date +%s)
suite_elapsed=$((suite_end - suite_start))
echo "=== Summary ($MODE): $passed passed, $failed failed, $skipped skipped [${suite_elapsed}s] ==="
if [ $failed -gt 0 ]; then
    echo "Failures:$failures"
    exit 1
fi
