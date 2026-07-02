#!/bin/sh
# Build the self-hosted formatter (bnfmt).
#
# Convenience wrapper around the bootstrap → bnc → cmd/bnfmt pipeline.
# Not used by the test/conformance harness; those have their own
# build helpers in scripts/lib/build-compilers.sh.
#
# The output path is required (no implicit default) so concurrent
# invocations — e.g. from different worktrees — don't clobber each
# other.  Build scratch goes through `mktemp -d` for the same reason.
#
# Usage:
#   ./scripts/build-bnfmt.sh -o <path>         # release (-O2)
#   ./scripts/build-bnfmt.sh -o <path> --debug # -O0 -g (slower, debuggable)
#   ./scripts/build-bnfmt.sh -h                # help
#
# After building:
#   <path> <file.bn>          format to stdout
#   <path> -w <file.bn>       rewrite the file in place
#   <path> --check <file.bn>  exit non-zero if the file is not formatted

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

echo "Building bnfmt: $MODE_DESC → $OUT"
echo "  source root:    $BINATE_DIR"
echo "  bootstrap:      $BOOTSTRAP_DIR"
echo "  build scratch:  $BUILD_DIR"
echo

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"

# Two-step BUILDER → gen1 → final build, so any difference between the
# BUILDER's compiled-in mangled-symbol literals and current-source's
# literals can't reach the released binary.  gen1 is a cmd/bnc built
# by the BUILDER and linked against the BUILDER's C runtime (its OLD
# self-references resolve there); gen1's compiled-in codegen is
# CURRENT source's codegen, so its OUTPUTS use the current literals.
# The final binary is then emitted by gen1 from current source,
# linked against the checkout's C runtime — fully consistent.

GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

echo "  Stage 1: BUILDER → gen1 ..."
# Stage 1's inner -I/-L resolve cmd/bnc's builtin + stdlib deps from the
# BUILDER's frozen bundle only (--base "$BUILDER_LIB" --prepend "$BINATE_DIR");
# the bnc source cone may only use features the BUILDER has, so no source
# fallback.  Full rationale: scripts/lib/build-compilers.sh build_gen1.
"$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    "$BINATE_DIR/cmd/bnc" -- \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --runtime "$BUILDER_RUNTIME" \
    --build-dir "$GEN1_DIR/build" \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc"

echo "  Stage 2: gen1 → bnfmt ..."
if [ -n "$DBG_FLAG" ]; then
    "$GEN1_BNC" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
        --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        "$DBG_FLAG" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bnfmt"
else
    "$GEN1_BNC" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
        -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
        --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bnfmt"
fi

echo
echo "Built: $OUT"
echo
echo "Try:"
echo "  $OUT $BINATE_DIR/cmd/bnfmt/main.bn    # format a file to stdout"
