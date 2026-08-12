#!/bin/sh
# Build the self-hosted compiler (bnc).
#
# Convenience wrapper around the BUILDER → gen1 → final bnc build
# (fetch-builder.sh downloads the BUILDER bnc, which compiles cmd/bnc into
# gen1, which compiles cmd/bnc into the final native bnc; no bootstrap/Go
# needed -- see the two-step rationale below).  Not used by the test/
# conformance harness; those have their own build helpers in
# scripts/lib/build-compilers.sh.
#
# The output path is required (no implicit default) so concurrent
# invocations — e.g. from different worktrees — don't clobber each
# other.  Build scratch goes through `mktemp -d` for the same reason.
#
# Usage:
#   ./scripts/build-bnc.sh -o <path>         # release (-O2)
#   ./scripts/build-bnc.sh -o <path> --debug # -O0 -g (slower, debuggable)
#   ./scripts/build-bnc.sh -h                # help
#
# --target <key> cross-compiles Stage 2 for a bnc --target key (e.g.
# aarch64-linux, x86_64-darwin); omitted builds for the host arch.
#
# After building:
#   <path> -o <bin> <file.bn|dir>         compile a program
#   <path> --emit-llvm <file.bn>          emit LLVM IR text
#   <path> --test -I <dir> -L <dir> <pkg> run unit tests in a package

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT=""
DEBUG=0
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            OUT="$2"
            shift 2
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --target=*)
            TARGET="${1#--target=}"
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            echo "try: $0 --help" >&2
            exit 1
            ;;
    esac
done

if [ -z "$OUT" ]; then
    echo "ERROR: output path is required" >&2
    echo "  usage: $0 -o <path> [--debug]" >&2
    echo "  try:   $0 --help" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [ "$DEBUG" = 1 ]; then
    CFLAGS="-O0"
    DBG_FLAG="-g"
    MODE_DESC="debug (-O0 -g)"
else
    CFLAGS="-O2"
    DBG_FLAG=""
    MODE_DESC="release (-O2)"
fi

echo "Building bnc: $MODE_DESC → $OUT"
echo "  source root:    $BINATE_DIR"
echo "  build scratch:  $BUILD_DIR"
echo

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"

# Two-step BUILDER → gen1 → final build, so any difference between the
# BUILDER's compiled-in mangled-symbol literals and current-source's
# literals can't reach the released binary.  gen1 is a cmd/bnc built
# by the BUILDER and linked against the BUILDER's C runtime (its OLD
# self-references resolve there); gen1's compiled-in codegen is
# CURRENT source's codegen, so its OUTPUTS use the current literals.
# The final binary is then emitted by gen1 from current source,
# linked against the checkout's C runtime — fully consistent.
#
# Stage 1's -I/-L resolve cmd/bnc's builtin + stdlib deps entirely from
# the BUILDER's frozen bundle (`--base "$BUILDER_LIB" --prepend "$BINATE_DIR"`):
# the bnc source cone may only use language/core/stdlib features the BUILDER has
# (BUILDER-compatibility), so source copies aren't used and there is no source
# fallback (pulling them in could hit a not-yet-in-BUILDER feature like `same`).
# Only pkg/binate (the compiler's own code) comes from source.  Full rationale:
# scripts/lib/build-compilers.sh build_gen1.

GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

echo "  Stage 1: BUILDER → gen1 ..."
"$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --build-dir "$GEN1_DIR/build" \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc"

echo "  Stage 2: gen1 → bnc ..."
# Cross-compile: when --target names a non-host target, gen1 (a host binary,
# built above) cross-EMITS the final bnc for that target.  The one key drives
# both bnc's #[build(...)] stdlib gating (target-specific impls, e.g. os's
# syscalls) and its clang cross-triple/flags (appendTargetFlags).  Passed to
# binate-paths too so any per-target search extras apply (a no-op for the hosted
# linux/macos targets, which #[build]-gate impls in place; matters for
# baremetal).  Empty --target = host build, byte-identical to before.
# Stage 1 is NOT cross-targeted: gen1 must run on THIS host.
TARGET_OPT=""
[ -n "$TARGET" ] && TARGET_OPT="--target $TARGET"
if [ -n "$DBG_FLAG" ]; then
    "$GEN1_BNC" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" $TARGET_OPT)" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" $TARGET_OPT)" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        $TARGET_OPT \
        "$DBG_FLAG" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bnc"
else
    "$GEN1_BNC" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" $TARGET_OPT)" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" $TARGET_OPT)" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        $TARGET_OPT \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bnc"
fi

echo
echo "Built: $OUT"
echo
echo "Try:"
echo "  $OUT -o /tmp/myprog file.bn                  # compile a program"
echo "  $OUT --emit-llvm file.bn                     # emit LLVM IR text"
echo "  $OUT --test -I $BINATE_DIR -L $BINATE_DIR pkg/foo  # run unit tests in pkg/foo"
