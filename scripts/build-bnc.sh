#!/bin/sh
# Build the self-hosted compiler (bnc).
#
# Convenience wrapper around the bootstrap → bnc → cmd/bnc pipeline
# (the bootstrap-interpreted compiler builds itself; the result is a
# native gen1 bnc).  Not used by the test/conformance harness; those
# have their own build helpers in scripts/lib/build-compilers.sh.
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
# After building:
#   <path> -o <bin> <file.bn|dir>         compile a program
#   <path> --emit-llvm <file.bn>          emit LLVM IR text
#   <path> --test -I <dir> -L <dir> <pkg> run unit tests in a package

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"

OUT=""
DEBUG=0

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

if [ ! -d "$BOOTSTRAP_DIR" ]; then
    echo "ERROR: bootstrap dir not found at $BOOTSTRAP_DIR" >&2
    echo "(Expected sibling of $BINATE_DIR; the workspace layout has the" >&2
    echo " bootstrap and binate repos as sibling directories.)" >&2
    exit 1
fi

BUILD_DIR="$(mktemp -d "/tmp/binate_build_XXXXXX")"
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
echo "  bootstrap:      $BOOTSTRAP_DIR"
echo "  build scratch:  $BUILD_DIR"
echo

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$BUILDER_LIB/runtime/binate_runtime.c"

# Two-step BUILDER → gen1 → final build, so any difference between the
# BUILDER's compiled-in mangled-symbol literals and current-source's
# literals can't reach the released binary.  gen1 is a cmd/bnc built
# by the BUILDER and linked against the BUILDER's C runtime (its OLD
# self-references resolve there); gen1's compiled-in codegen is
# CURRENT source's codegen, so its OUTPUTS use the current literals.
# The final binary is then emitted by gen1 from current source,
# linked against the checkout's C runtime — fully consistent.
#
# Stdlib (tier-1) resolves BUILDER-first: the gen1 -I/-L below list the
# $BUILDER_LIB/{ifaces/stdlib,impls/stdlib/common} roots AHEAD of the
# $BINATE_DIR copies, so stage-1 compiles cmd/bnc's stdlib deps against the
# BUILDER's frozen (BUILDER-compilable) bundle rather than current source.
# Current source stays as the fallback — and is the only source while the
# BUILDER's stdlib bundle is empty (pre-bnc-0.0.7), so the ordering is a no-op
# against such a BUILDER.  Core (tier-0) stays current-first: it's compiler-
# coupled, not a bundled component.

GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

echo "  Stage 1: BUILDER → gen1 ..."
"$BUILDER" \
    -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" \
    -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
    "$BINATE_DIR/cmd/bnc" -- \
    -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BUILDER_LIB/ifaces/stdlib:$BINATE_DIR/ifaces/stdlib:$BUILDER_LIB:$BUILDER_LIB/ifaces/core" \
    -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BUILDER_LIB/impls/stdlib/common:$BINATE_DIR/impls/stdlib/common:$BUILDER_LIB:$BUILDER_LIB/impls/core/common:$BUILDER_LIB/impls/core/libc" \
    --runtime "$BUILDER_RUNTIME" \
    --build-dir "$GEN1_DIR/build" \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc"

echo "  Stage 2: gen1 → bnc ..."
if [ -n "$DBG_FLAG" ]; then
    "$GEN1_BNC" \
        -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" \
        -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        "$DBG_FLAG" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bnc"
else
    "$GEN1_BNC" \
        -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" \
        -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
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
