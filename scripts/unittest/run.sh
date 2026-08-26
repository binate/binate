#!/bin/sh
# Usage: ./scripts/unittest/run.sh <mode> [filter...]
#
# Runs unit tests for all packages (or filtered packages) using the specified
# backend mode.
#
# Modes (chains of: builder=resolved BUILDER_VERSION binary running
# cmd/bnc, comp=compiler from current tree, int=bytecode VM).  The
# first link is the BUILDER_VERSION-resolved binary (a bnc-X.Y.Z
# bundle resolved via scripts/fetch-builder.sh).
#
#   builder-comp             BUILDER compiles bnc, which compiles and runs tests
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
export SCRIPT_DIR BINATE_DIR

# A compiled test binary inherits its current directory from here, and
# cmd/bnlint's integration tests load real packages from disk relative to CWD
# (see cmd/bnlint/main_test.bn).  Pin CWD to the repo root so "." resolves
# deterministically no matter where this script was invoked from.  Everything
# below already uses absolute ($BINATE_DIR-rooted) paths, so this is a no-op for
# every other package.
cd "$BINATE_DIR" || exit 1

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
for testfile in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/impls" -name '*_test.bn' -not -path '*/testdata/*' 2>/dev/null); do
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

# BATCH_MODE: on the double-VM lane (*-int-int), cmd/bni --test re-loads+lowers
# all of cmd/bni + each package's dep tree on EVERY per-package invocation — the
# lane's dominant per-shard floor.  cmd/bni --test is multi-package with a SHARED
# loader, so batching packages into ONE invocation pays the shared core (cmd/bni +
# types/ir/ast) once.  But batching ALL packages per shard loads ALL ~50 package
# impls on EVERY shard — a per-shard-CONSTANT floor no shard count can reduce.  So
# the batch runs a REPRESENTATIVE SUBSET (see the classification loop below):
#   - HEAVY = the INTINT_HEAVY representative set (types, ir — moderate-cost at
#     double-VM): TEST-sharded — loaded on EVERY shard, each running 1/N of its
#     own tests via --shard.  Collected into BATCH_HEAVY_PKGS.
#   - CHEAP packages (not .split.vm): PACKAGE-sharded — each assigned to ONE shard
#     by position, running its FULL tests there.  Collected into BATCH_LIGHT_PKGS.
#   - Other .split.vm packages (native/* backends, asm/*, lint/bnlint/bnfmt,
#     parser, irdata): SKIPPED here — priciest at double-VM, covered by the
#     single-VM / native lanes.  (Running ALL ~15 heavies was a ~16-min/shard load
#     floor that blew the 45-min cap; the real fix is bni perf.)
# An unsharded run (SHARD_COUNT=0) runs the subset full in one batch.  Off under
# --check-xpass (which needs the per-package XPASS detection path).  BATCH_*_SKIPS
# accumulate package-qualified skip patterns (pkg:pattern) for their batch.
BATCH_MODE=0
if [ "$CHECK_XPASS" -eq 0 ]; then
    case "$MODE" in *-int-int) BATCH_MODE=1 ;; esac
fi
# The double-VM representative set: the .split.vm packages whose tests are only
# MODERATELY expensive under double-VM — types (typecheck) and ir (IR build),
# measured ~0.9s/test.  Deliberately EXCLUDES codegen / vm / native-* etc.: their
# tests compile or RUN whole programs, which under the VM-interpreting-the-VM
# becomes ~100× (vm's own tests run a bytecode VM, so double-VM makes them
# VM-on-VM-on-VM) — a full shard of {types,ir,vm,codegen} measured 5h44m locally.
# Running the type-checker + IR builder under the VM still exercises the double-VM
# path thoroughly; codegen/vm/native double-VM coverage waits on bni perf work.
# Kept test-sharded; every other .split.vm package is dropped from this lane.
INTINT_HEAVY="pkg/binate/types pkg/binate/ir"
BATCH_LIGHT_PKGS=""
BATCH_LIGHT_SKIPS=""
BATCH_HEAVY_PKGS=""
BATCH_HEAVY_SKIPS=""

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

    # Package key (pkg/binate/ir -> pkg-binate-ir), used by all the marker
    # files below (xfail / skip-pkg / skip / split).
    xfail_key="$(echo "$pkg" | tr '/' '-')"

    # BATCH path (double-VM lane): collect non-excluded packages into the light or
    # heavy batch (see BATCH_MODE above) instead of running each individually.
    # Exclusions (native-only / xfail / skip-pkg) are still decided per package.
    # Bypasses the per-package shard-select / split / runner_test below.
    if [ "$BATCH_MODE" -eq 1 ]; then
        # Native-only packages are injected (not interpreted) under the VM;
        # pkg/std/debug is the deliberate exception (its BC_STACK_FRAMES path is
        # the point).  See the non-batch native-only block below.
        case "$pkg" in
            pkg/std/debug) : ;;
            pkg/std/*|pkg/builtins/rt|pkg/builtins/startup)
                pkgskipped=$((pkgskipped + 1))
                continue ;;
        esac
        # xfail: expected to fail here — keep it OUT of the batch (a real failure
        # among passing packages would obscure it).  --check-xpass already
        # disables BATCH_MODE, so this is the plain skip-the-xfailed-package case.
        b_xf="$SCRIPT_DIR/${xfail_key}.xfail.${MODE}"
        [ -f "$b_xf" ] || b_xf="$SCRIPT_DIR/${xfail_key}.xfail.all"
        if [ -f "$b_xf" ]; then
            xfailed=$((xfailed + 1))
            continue
        fi
        # skip-pkg: omitted from this lane (too slow / no added coverage).
        if [ -f "$SCRIPT_DIR/${xfail_key}.skip-pkg.${MODE}" ]; then
            pkgskipped=$((pkgskipped + 1))
            continue
        fi
        # This package's per-test .skip patterns, qualified as pkg:pattern so they
        # only affect THIS package in the shared batch.
        b_sf="$SCRIPT_DIR/${xfail_key}.skip.${MODE}"
        b_pkg_skips=""
        if [ -f "$b_sf" ]; then
            for b_pat in $(tr ',' ' ' < "$b_sf"); do
                b_pkg_skips="$b_pkg_skips,$pkg:$b_pat"
            done
        fi
        # int-int representative subset: the double-VM lane runs only the
        # INTINT_HEAVY set test-sharded (loaded on every shard, 1/N tests each)
        # PLUS all cheap (non-.split.vm) packages package-sharded.  Every OTHER
        # .split.vm package — codegen, vm, the native/* backends, asm/*, lint/
        # bnlint/bnfmt, parser, irdata — is SKIPPED here: their tests compile or
        # RUN whole programs, which is pathological under the VM-interpreting-the-
        # VM (native/arm32's 353 tests alone > 25 min; a shard of {types,ir,vm,
        # codegen} took 5h44m — vm's own tests run a VM, so double-VM is
        # VM-on-VM-on-VM).  Their coverage comes from the single-VM (-int /
        # -comp-int) and native lanes; the double-VM path itself is package-
        # agnostic, so running the type-checker + IR builder under it exercises it.
        # The real fix is bni perf (see explorations/claude-todo.md); until then
        # this keeps the lane green and useful.  int-int-specific — the single-VM
        # lanes have no such cost and still use .split.vm via the non-batch
        # shard-selection below.
        b_split="$SCRIPT_DIR/${xfail_key}.split.${MODE}"
        if [ ! -f "$b_split" ]; then
            case "$MODE" in *int*) b_split="$SCRIPT_DIR/${xfail_key}.split.vm" ;; esac
        fi
        b_is_heavy=0
        case " $INTINT_HEAVY " in *" $pkg "*) b_is_heavy=1 ;; esac
        if [ "$SHARD_COUNT" -eq 0 ]; then
            # Unsharded: run the subset (INTINT_HEAVY + cheap) full in one batch,
            # but still exclude the non-subset expensive (.split.vm) packages.
            if [ "$b_is_heavy" -eq 0 ] && [ -f "$b_split" ]; then
                pkgskipped=$((pkgskipped + 1)); continue
            fi
            BATCH_LIGHT_PKGS="$BATCH_LIGHT_PKGS $pkg"
            BATCH_LIGHT_SKIPS="$BATCH_LIGHT_SKIPS$b_pkg_skips"
            continue
        fi
        if [ "$b_is_heavy" -eq 1 ]; then
            # Core pipeline: test-shard — on every shard, tests split 1/N via --shard.
            BATCH_HEAVY_PKGS="$BATCH_HEAVY_PKGS $pkg"
            BATCH_HEAVY_SKIPS="$BATCH_HEAVY_SKIPS$b_pkg_skips"
            continue
        fi
        if [ -f "$b_split" ]; then
            # Expensive but NOT in the int-int subset: skip for this lane.
            pkgskipped=$((pkgskipped + 1)); continue
        fi
        # Cheap package: package-shard — assigned to ONE shard by position
        # (shard_pos % count == index-1), running its full tests there.  shard_pos
        # advances for every cheap package on every shard identically (deterministic
        # order + exclusions), so each lands on exactly one shard.
        if [ $((shard_pos % SHARD_COUNT)) -eq $((SHARD_IDX - 1)) ]; then
            BATCH_LIGHT_PKGS="$BATCH_LIGHT_PKGS $pkg"
            BATCH_LIGHT_SKIPS="$BATCH_LIGHT_SKIPS$b_pkg_skips"
        fi
        shard_pos=$((shard_pos + 1))
        continue
    fi

    # Shard selection.  By default a package lands on ONE shard by position
    # (shard_pos % n == i - 1), whole.  But a package marked
    # <pkg-key>.split.<mode> has its TESTS split across ALL shards instead: it
    # runs on every shard, forwarding TEST_SHARD_IDX/TEST_SHARD_COUNT to the test
    # runner (bni --test --shard-index/--shard-count runs `pos % count == idx-1`
    # of the package's tests).  That spreads a single package too heavy to fit one
    # shard, rather than SKIPPING it (which loses its double-VM coverage).  Only
    # the bni-based runners honor the forwarded shard; other modes ignore it.
    # Packages dropped by position-sharding are NOT counted in `skipped` (another
    # shard runs them).
    # A per-mode <pkg-key>.split.<mode> marks one package; <pkg-key>.split.vm marks
    # it for EVERY VM mode (any mode with an `int` leg — single or double VM), the
    # ones where compile-heavy packages blow the shard timeout.  (Splitting a
    # package that would have fit is harmless — it just runs its tests in slices.)
    split_file="$SCRIPT_DIR/${xfail_key}.split.${MODE}"
    if [ ! -f "$split_file" ]; then
        case "$MODE" in *int*) split_file="$SCRIPT_DIR/${xfail_key}.split.vm" ;; esac
    fi
    TEST_SHARD_IDX=""
    TEST_SHARD_COUNT=""
    if [ "$SHARD_COUNT" -gt 0 ]; then
        if [ -f "$split_file" ]; then
            TEST_SHARD_IDX="$SHARD_IDX"
            TEST_SHARD_COUNT="$SHARD_COUNT"
            shard_pos=$((shard_pos + 1))
        elif [ $((shard_pos % SHARD_COUNT)) -ne $((SHARD_IDX - 1)) ]; then
            shard_pos=$((shard_pos + 1))
            continue
        else
            shard_pos=$((shard_pos + 1))
        fi
    fi
    export TEST_SHARD_IDX TEST_SHARD_COUNT

    # Native-only packages are ALWAYS injected (native) in production — the
    # bytecode VM never interprets them.  Unit-testing one under an interpreter
    # mode lowers the package itself to bytecode, a configuration that never
    # ships (and for a __c_call package like pkg/std/os the --test runner rejects
    # it at the frontend — TypecheckPackages sets Checker.Interpreted — as a clean
    # "cannot be interpreted" error rather than running).  The set:
    # pkg/std/* (the injected stdlib) plus pkg/builtins/{rt,startup} (native
    # substrate — rt uses __c_call for malloc/free/exit/…; startup's entry glue
    # _entry is a __c_call'ing c_export'd `main`).  Skip them under the int
    # modes; the stdlib's cross-mode coverage is the conformance/stdlib suite
    # (run.sh under conformance/, where the stdlib is INJECTED), and rt's/startup's
    # logic is covered by their compiled-mode unit tests.  This is a by-design
    # exclusion, NOT a perf .skip-pkg nor a failure .xfail.
    #
    # pkg/std/debug is the deliberate exception: it is the one stdlib package
    # EXEMPT from native injection (scripts/hygiene/stdlib-injected.sh), so under
    # the VM its _stack_frames intrinsic lowers to BC_STACK_FRAMES and walks the
    # VM's own frame stack.  Interpreting it is the POINT — that is how the
    # bytecode stack-capture path gets exercised; injecting/skipping it would
    # bypass exactly the code the test verifies.  So it must NOT be skipped here.
    case "$MODE" in
        *int*)
            case "$pkg" in
                pkg/std/debug)
                    : # fall through — interpret it (see above)
                    ;;
                pkg/std/*|pkg/builtins/rt|pkg/builtins/startup)
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
    # the result handler can interpret pass/fail as XPASS/XFAIL.  (xfail_key was
    # computed above, at the shard-selection step.)
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

# Run the collected batches (double-VM lane), then map cmd/bni's per-package
# ok/FAIL/? lines back to the tallies.  Two invocations so the two sharding
# policies coexist on one shard: the LIGHT batch (already package-sharded to this
# shard) runs its packages' FULL tests (no --shard); the HEAVY batch (.split.vm,
# loaded on every shard) runs 1/N of each package's tests (--shard).  Each cmd/bni
# load pays the shared core (cmd/bni + types/ir/ast) once for its whole batch, so a
# shard's floor is core + (its light subset's impls) + (the heavy impls), not all
# ~50 impls.  Output is tee'd to a temp file when verbose (live progress in CI; a
# diagnosable tail survives a timeout) and grepped afterward.
if [ "$BATCH_MODE" -eq 1 ] && { [ -n "$BATCH_LIGHT_PKGS" ] || [ -n "$BATCH_HEAVY_PKGS" ]; }; then
    b_tmp="$(mktemp)"
    : > "$b_tmp"
    # emit_batch runs one batch, appending its output to $b_tmp; streams live to
    # stdout when verbose (CI passes -v), else silent-to-file.
    emit_batch() {
        if [ "$VERBOSE" -eq 1 ]; then
            runner_test_batch "$1" "$2" "$3" 2>&1 | tee -a "$b_tmp"
        else
            runner_test_batch "$1" "$2" "$3" >> "$b_tmp" 2>&1
        fi
    }
    b_start=$(date +%s)
    if [ -n "$BATCH_LIGHT_PKGS" ]; then
        b_ln=$(echo $BATCH_LIGHT_PKGS | wc -w | tr -d ' ')
        if [ "$VERBOSE" -eq 1 ]; then echo "STARTING (batched light/full): $b_ln packages"; fi
        emit_batch "$BATCH_LIGHT_PKGS" "${BATCH_LIGHT_SKIPS#,}" 0
    fi
    if [ -n "$BATCH_HEAVY_PKGS" ]; then
        b_hn=$(echo $BATCH_HEAVY_PKGS | wc -w | tr -d ' ')
        if [ "$VERBOSE" -eq 1 ]; then echo "STARTING (batched heavy/1-of-$SHARD_COUNT): $b_hn packages"; fi
        emit_batch "$BATCH_HEAVY_PKGS" "${BATCH_HEAVY_SKIPS#,}" 1
    fi
    b_elapsed=$(( $(date +%s) - b_start ))
    if [ "$VERBOSE" -eq 1 ]; then echo "batched run: ${b_elapsed}s"; fi
    for p in $BATCH_LIGHT_PKGS $BATCH_HEAVY_PKGS; do
        # cmd/bni prints one line per package: `FAIL<TAB>pkg`, `ok  <TAB>pkg<TAB>…`,
        # or `?   <TAB>pkg<TAB>[no test functions]` (also `ok` with the full count
        # for a heavy package whose tests all fell on other shards).  A package with
        # NO line means the batch died before reaching it — count that a failure.
        if grep -q "^FAIL	${p}$" "$b_tmp"; then
            failed=$((failed + 1))
            failures="$failures $p"
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "FAIL: $p (batched)"
            fi
        elif grep -q "^ok  	${p}	" "$b_tmp"; then
            passed=$((passed + 1))
            if [ "$VERBOSE" -eq 1 ]; then echo "PASS: $p (batched)"; fi
        elif grep -q "^?   	${p}	" "$b_tmp"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failures="$failures $p(no-result)"
            if [ "$QUIET" -eq 0 ] || [ "$VERBOSE" -eq 1 ]; then
                echo ""
                echo "FAIL: $p (batched — no per-package result; batch aborted?)"
            fi
        fi
    done
    # Non-verbose runs did not stream the output; on failure surface its tail so
    # the batch abort / failing package is diagnosable.  (Verbose already streamed
    # everything via tee.)
    if [ "$failed" -gt 0 ] && [ "$QUIET" -eq 0 ] && [ "$VERBOSE" -eq 0 ]; then
        tail -20 "$b_tmp" | sed 's/^/  /'
    fi
    rm -f "$b_tmp"
fi

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
