#!/bin/sh
# Build the self-hosted bytecode interpreter (bni).
#
# Convenience wrapper that builds gen2 (BUILDER → gen1 → gen2, via build-bnc.sh)
# and compiles cmd/bni with it, intended for playing with bni interactively
# (notably: `bni --repl`).  gen2 is a fully from-tree bnc; see the gen1/gen2
# definitions in scripts/lib/build-compilers.sh.
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
# --target <key> cross-compiles the tool (gen2 stays host and cross-emits) for a
# bnc --target key (e.g. aarch64-linux, x86_64-darwin); omitted builds host arch.
#
# After building:
#   <path> <file.bn|dir> [args]              run a main package (file or dir)
#   <path> --repl <file.bn|dir>              REPL against the loaded module
#   <path> --test <pkg> -I <iface> -L <impl> run unit tests in a package

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

echo "Building bni: $MODE_DESC → $OUT"
echo "  source root:    $BINATE_DIR"
echo "  build scratch:  $BUILD_DIR"
echo

# Build gen2 — a fully from-tree bnc — then compile the tool with it.  gen2 is
# BUILDER → gen1 → gen2 (all handled by build-bnc.sh: BUILDER compiles cmd/bnc
# against the BUILDER stdlib → gen1; gen1 recompiles cmd/bnc against the TREE
# stdlib → gen2).  Building the tool with gen2 (not gen1) keeps the
# from-tree-bnc / tree-stdlib pairing clean (see scripts/lib/build-compilers.sh)
# and lets the tool build pick up the tree's own codegen improvements/fixes.
# gen2 is always a host binary; --target applies only to the tool compile below.
GEN2_BNC="$BUILD_DIR/gen2-bnc"
echo "  Building gen2 (BUILDER → gen1 → gen2) ..."
"$SCRIPT_DIR/build-bnc.sh" -o "$GEN2_BNC" >&2

echo "  Compiling bni with gen2 ..."
# --target: gen2 (host) cross-EMITS the tool for a non-host target — the key drives
# bnc's #[build(...)] stdlib gating (target-specific impls, e.g. os's syscalls) and
# its clang cross-triple/flags, and is passed to binate-paths for any per-target
# search extras (a no-op for the hosted linux/macos targets; matters for baremetal).
# Empty --target = host build.
TARGET_OPT=""
[ -n "$TARGET" ] && TARGET_OPT="--target $TARGET"
"$GEN2_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" $TARGET_OPT)" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" $TARGET_OPT)" \
    --build-dir "$BUILD_DIR" \
    --cflag "$CFLAGS" \
    $TARGET_OPT \
    ${DBG_FLAG:+$DBG_FLAG} \
    -o "$OUT" \
    "$BINATE_DIR/cmd/bni"

echo
echo "Built: $OUT"
echo
echo "Try:"
echo "  $OUT <file.bn|dir> [args]              # run a main package (first positional; file or dir)"
echo "  $OUT --repl <file.bn|dir>              # interactive REPL against the loaded module"
echo "  $OUT --test pkg/foo -I <iface> -L <impl>   # run unit tests (paths via scripts/binate-paths.sh)"
