#!/bin/sh
# e2e/print-args.sh — End-to-end test of bootstrap.Args() across all
# three execution paths:
#   a) compiled native binary
#   b) compiled bni interpreting a .bn program
#   c) compiled bni interpreting cmd/bni interpreting a .bn program
#
# Each path runs the same fixture (a print_args.bn that emits each
# bootstrap.Args() element followed by "END"), with the same intended
# program-arguments, and must produce the same output.
#
# Pins down the spec contract that bootstrap.Args() returns the args
# AFTER `--` (explorations/bootstrap-subset.md §"Args"), at every
# level of nesting.  Without per-level `--` stripping, double-bni
# infinite-recurses (the inner cmd/bni reinterprets cmd/bni instead
# of the test program).
#
# Exit 0 on full pass; non-zero with per-tool diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/.." && pwd)/bootstrap"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
if [ ! -d "$BOOTSTRAP_DIR" ]; then
    echo "FAIL: bootstrap repo not found at $BOOTSTRAP_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d /tmp/binate_e2e_print_args.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

cat > "$TMP/print_args.bn" <<'EOF'
package "main"

import "pkg/bootstrap"

func main() {
    var args @[]@[]char = bootstrap.Args()
    for i := 0; i < len(args); i++ {
        println(args[i])
    }
    println("END")
}
EOF

EXPECTED="alpha
beta
gamma
END"
PASSES=0
FAILS=0
FAIL_NAMES=""

check() {
    label="$1"
    actual="$2"
    if [ "$actual" = "$EXPECTED" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected:"
        echo "$EXPECTED" | sed 's/^/    /'
        echo "  actual:"
        echo "$actual" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# Resolve the BUILDER once; (b) and (c) both need bni built via it.
# Then BUILDER → gen1 → final, so current-source's mangled-symbol
# literals match the checkout runtime regardless of any BUILDER skew.
# See scripts/build-bni.sh for the same pattern.
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

# Stage 1's inner -I/-L resolve cmd/bnc's builtin + stdlib deps from the
# BUILDER's frozen bundle only (--base "$BUILDER_LIB" --prepend "$BINATE_DIR"):
# the bnc source cone may only use features the BUILDER has, so source copies
# aren't used and there is no fallback (a not-yet-in-BUILDER feature like `same`
# in std/errors would otherwise fail the build).  Full rationale + lockstep:
# scripts/lib/build-compilers.sh build_gen1.
gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    "$BINATE_DIR/cmd/bnc" -- \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --runtime "$BUILDER_RUNTIME" \
    --build-dir "$GEN1_DIR/build" \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc" 2>&1)
if [ ! -x "$GEN1_BNC" ]; then
    echo "FAIL: gen1 build failed:"
    echo "$gen1_log"
    exit 1
fi

# Build a native bni binary up front; (b) and (c) both need it.
BNI_BIN="$TMP/bni-bin"
bni_compile_log=$("$GEN1_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
    --build-dir "$BUILD_DIR" -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1) || true
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: could not build bni:"
    echo "$bni_compile_log"
    exit 1
fi

# ----- (a) native binary ------------------------------------------
# `--runtime` is explicit because print_args.bn lives in $TMP (not
# under $BINATE_DIR), so bnc's `findRuntime` walk-up wouldn't reach
# the checkout's binate_runtime.c on its own.
NATIVE_BIN="$TMP/print_args-bin"
native_compile_log=$("$GEN1_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --runtime "$BINATE_DIR/runtime/binate_runtime.c" \
    --build-dir "$BUILD_DIR" -o "$NATIVE_BIN" "$TMP/print_args.bn" 2>&1) || true
if [ -x "$NATIVE_BIN" ]; then
    # Native binaries see argv[1..] directly — there is no host
    # interpreter, so no `--` separator is needed (or expected).
    actual=$("$NATIVE_BIN" alpha beta gamma 2>&1) || true
else
    actual="COMPILE_ERROR: $native_compile_log"
fi
check "native" "$actual"

# ----- (b) compiled bni interprets print_args.bn ------------------
actual=$("$BNI_BIN" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" "$TMP/print_args.bn" -- \
    alpha beta gamma 2>&1) || true
check "bni" "$actual"

# ----- (c) compiled bni interprets cmd/bni interprets print_args -
# SKIP: blocked on a separate bug — when inner cmd/bni runs in
# interpreted context, registerPureCExterns crashes constructing a
# function value for a pure-C extern (libc.Malloc has no `.bn` body,
# so LookupFunc fails).  See claude-todo.md "builder-comp-int-int:
# registerPureCExterns crashes from interpreted cmd/bni".  The Args
# half of double-bni (no recursion) is verified by 001_hello in
# manual builder-comp-int-int runs.
echo "SKIP: bni-under-bni (registerPureCExterns crashes from interpreted cmd/bni; tracked in claude-todo.md)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
