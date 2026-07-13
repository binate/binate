#!/bin/sh
# e2e/os-args.sh — End-to-end check of pkg/std/os's Args() against a real
# process argv, on BOTH execution paths: a compiled native binary, and the same
# program interpreted by cmd/bni.
#
# os.Args() returns the command-line arguments as @[]readonly @[]readonly char,
# indexed like Go's os.Args: element 0 the program name, elements 1.. the
# arguments.  Unit tests pin the shaping logic on a synthetic list, and
# conformance/stdlib/os/011_args pins the no-argument case cross-mode; neither
# pins the with-REAL-args path, because the conformance runner passes a program
# no arguments.  So this compiles/interprets a fixture over a known argv and
# checks that os.Args() surfaces exactly [<program name>, args...].
#
# The fixture prints len(Args()) then the arguments (Args()[1..]) only — NOT
# element 0.  Element 0 is the program-name slot, whose CONTENT differs by path
# (an empty placeholder when compiled — nothing exposes argv[0] there yet — vs.
# the program path when interpreted, which cmd/bni installs via os.SetArgs), so
# a cross-path check must skip it; the argument elements are identical either way.
#
# Compiling needs a gen1 (checkout-source) compiler, NOT the BUILDER directly:
# os.Args()/SetArgs postdate the pinned BUILDER's frozen stdlib bundle, so the
# fixture and cmd/bni must link against the current pkg/std/os.  Mirrors
# e2e/print-args.sh's BUILDER -> gen1 -> build-with-checkout-paths shape.
#
# Exit 0 on full pass; non-zero with a diff on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo "SKIP: os-args unsupported on $(uname -s)"; exit 0 ;;
esac

TMP="$(mktemp -d /tmp/binate_e2e_os_args.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# Fixture: print the argument count, then each ARGUMENT (Args()[1..]) wrapped in
# brackets — element 0 (the program-name slot) is skipped because its content is
# path-dependent.
cat > "$TMP/os_args.bn" <<'EOF'
package "main"

import "pkg/std/os"

func main() {
	var a @[]readonly @[]readonly char = os.Args()
	println(len(a))
	for i := 1; i < len(a); i++ {
		print("[")
		print(a[i])
		println("]")
	}
}
EOF

# ----- Build gen1 (a native, checkout-source compiler). -----
# BUILDER interprets cmd/bnc (checkout source); the inner -I/-L resolve cmd/bnc's
# own deps from the BUILDER's frozen bundle (with source prepended), because the
# bnc source cone may only use features the BUILDER already has.  See
# scripts/lib/build-compilers.sh build_gen1 for the full rationale.
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"
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
    echo "FAIL: gen1 build failed:" >&2
    echo "$gen1_log" | sed 's/^/  /' >&2
    exit 1
fi

# Common checkout -I/-L (fixture and cmd/bni both link against the current stdlib).
CK_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CK_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
CK_RT="$BINATE_DIR/runtime/binate_runtime.c"

# ----- Build the fixture (native) and cmd/bni (native), both via gen1. -----
ARGS_BIN="$TMP/os_args-bin"
compile_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$ARGS_BIN" "$TMP/os_args.bn" 2>&1) || true
if [ ! -x "$ARGS_BIN" ]; then
    echo "FAIL: Binate compile of the os.Args fixture failed" >&2
    echo "$compile_log" | sed 's/^/  /' >&2
    exit 1
fi
BNI_BIN="$TMP/bni-bin"
bni_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1) || true
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: could not build cmd/bni" >&2
    echo "$bni_log" | sed 's/^/  /' >&2
    exit 1
fi

PASSES=0
FAILS=0
FAIL_NAMES=""

check() {
    label="$1"
    expected="$2"
    actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected:"; printf '%s\n' "$expected" | sed 's/^/    /'
        echo "  actual:";   printf '%s\n' "$actual"   | sed 's/^/    /'
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

WITH_ARGS="4
[alpha]
[beta]
[gamma]"

# (a) compiled native binary: argv[1..] are seen directly (no host, no `--`).
check "compiled/with-args" "$WITH_ARGS" "$("$ARGS_BIN" alpha beta gamma 2>&1)"
check "compiled/no-args"   "1"          "$("$ARGS_BIN" 2>&1)"

# (b) cmd/bni interpreting the fixture: the program's args come after `--`, and
# cmd/bni installs them (via os.SetArgs) so os.Args() surfaces them.
check "interp/with-args" "$WITH_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/os_args.bn" -- alpha beta gamma 2>&1)"
check "interp/no-args"   "1" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/os_args.bn" 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
