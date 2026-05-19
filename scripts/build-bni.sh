#!/bin/sh
# Build the self-hosted bytecode interpreter (bni).
#
# Convenience wrapper around the bootstrap → bnc → cmd/bni pipeline,
# intended for playing with bni interactively (notably: `bni --repl`).
# Not used by the test/conformance harness; those have their own
# build helpers in scripts/lib/build-compilers.sh.
#
# The output path is required (no implicit default) so concurrent
# invocations — e.g. from different worktrees — don't clobber each
# other.  Build scratch goes through `mktemp -d` for the same reason.
#
# Usage:
#   ./scripts/build-bni.sh -o <path>         # release (-O2)
#   ./scripts/build-bni.sh -o <path> --debug # -O0 -g (slower, debuggable)
#   ./scripts/build-bni.sh -h                # help
#
# After building:
#   <path> <file.bn|dir>                  run a program
#   <path> --repl <file.bn|dir>           REPL against the loaded module
#   <path> --test [-root <dir>] <pkg>     run unit tests in a package

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

echo "Building bni: $MODE_DESC → $OUT"
echo "  source root:    $BINATE_DIR"
echo "  bootstrap:      $BOOTSTRAP_DIR"
echo "  build scratch:  $BUILD_DIR"
echo

BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
if [ -n "$DBG_FLAG" ]; then
    "$BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- \
        --root "$BINATE_DIR" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        "$DBG_FLAG" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bni"
else
    "$BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- \
        --root "$BINATE_DIR" \
        --build-dir "$BUILD_DIR" \
        --cflag "$CFLAGS" \
        -o "$OUT" \
        "$BINATE_DIR/cmd/bni"
fi

echo
echo "Built: $OUT"
echo
echo "Try:"
echo "  $OUT <file.bn>                       # run a program"
echo "  $OUT --repl <file.bn>                # interactive REPL against the loaded module"
echo "  $OUT --test -root $BINATE_DIR pkg/foo  # run unit tests in pkg/foo"
