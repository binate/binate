#!/bin/sh
# e2e/os-args.sh — End-to-end check of pkg/std/os's Args() against a real
# process argv, on the compiled path.
#
# os.Args() returns the command-line arguments as a fully-readonly
# @[]readonly @[]readonly char, indexed like Go's os.Args: element 0 the program
# name (currently an empty placeholder — nothing exposes argv[0] yet), elements
# 1.. the arguments.  Unit tests pin the shaping logic on a synthetic list, and
# conformance/stdlib/os/011_args pins the no-argument case cross-mode; neither
# can pin the with-REAL-args path, because the conformance runner passes a
# program no arguments.  So this compiles a fixture to a native binary and runs
# it with a known argv, checking that os.Args() surfaces exactly [placeholder,
# args...].
#
# COMPILED PATH ONLY.  Under the interpreter (cmd/bni) os.Args() returns the
# HOST interpreter's own argv, because pkg/std/os is injected into the VM as
# host-native code and so reaches bni's native bootstrap.Args() rather than the
# program's args — a known cross-mode plumbing gap tracked in claude-todo.md and
# xfail'd in 011_args's -int modes.  This e2e deliberately does not exercise the
# interpreter, to avoid encoding that broken behavior as an expectation.
#
# Compiling needs a gen1 (checkout-source) compiler, NOT the BUILDER directly:
# os.Args() postdates the pinned BUILDER's frozen stdlib bundle, so the fixture
# must link against the current pkg/std/os.  Mirrors e2e/print-args.sh's
# BUILDER -> gen1 -> compile-fixture-with-checkout-paths shape.
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

# Fixture: print the argument count, then each element wrapped in brackets so the
# empty program-name placeholder is visible as "[]" and any stray whitespace in
# an argument would show.
cat > "$TMP/os_args.bn" <<'EOF'
package "main"

import "pkg/std/os"

func main() {
	var a @[]readonly @[]readonly char = os.Args()
	println(len(a))
	for i := 0; i < len(a); i++ {
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

# ----- Compile the fixture with gen1 against the CHECKOUT stdlib + runtime, -----
# so it links against the current pkg/std/os (the one that defines Args()).
ARGS_BIN="$TMP/os_args-bin"
compile_log=$("$GEN1_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --runtime "$BINATE_DIR/runtime/binate_runtime.c" \
    --build-dir "$BUILD_DIR" -o "$ARGS_BIN" "$TMP/os_args.bn" 2>&1) || true
if [ ! -x "$ARGS_BIN" ]; then
    echo "FAIL: Binate compile of the os.Args fixture failed" >&2
    echo "$compile_log" | sed 's/^/  /' >&2
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

# A native binary sees argv[1..] directly (no host interpreter, no `--`).
# element 0 is the empty program-name placeholder, then the three arguments.
check "with-args" "4
[]
[alpha]
[beta]
[gamma]" "$("$ARGS_BIN" alpha beta gamma 2>&1)"

# No arguments: just the single program-name placeholder.
check "no-args" "1
[]" "$("$ARGS_BIN" 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
