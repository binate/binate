#!/bin/sh
# e2e/fmt-os-args.sh — End-to-end check that pkg/stdx/fmt renders a REAL os.Args()
# element as text, on BOTH execution paths: a compiled native binary, and the same
# program interpreted by cmd/bni.
#
# os.Args() returns @[]readonly @[]readonly char, so an element has type `readonly
# @[]readonly char` — an outer-`readonly`-qualified managed char-slice.  fmt's
# writeArg fast type switch matches only the four UNqualified char-slice spellings,
# so before ce758276 `fmt.Printf("%s", os.Args()[i])` rendered `%!?(unknown)` — the
# single most common thing a program prints (its own argv).  The fix recovers a
# wrapped/qualified char-slice via reflection (dynamic type peels to KIND_STRING).
# conformance/1196_fmt_wrapped_string pins the exact dynamic type synthetically;
# this pins the REAL os.Args() element flowing through fmt, end to end, on both the
# compiled and interpreted paths (the conformance runner passes no arguments, so it
# cannot).
#
# The fixture prints `argc=<len>` via `%d` and each ARGUMENT (Args()[1..]) via `%s`.
# It does not print element 0's content (the path-dependent program name, which
# differs between the compiled-binary and interpreted runs), only the argument
# count and the arguments — identical either way.
#
# Compiling needs a gen1 (checkout-source) compiler, NOT the BUILDER directly:
# os.Args()/SetArgs postdate the pinned BUILDER's frozen stdlib bundle, so the
# fixture and cmd/bni must link against the current pkg/std/os.  Uses the standard
# BUILDER -> gen1 -> build-with-checkout-paths shape.
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
    *) echo "SKIP: fmt-os-args unsupported on $(uname -s)"; exit 0 ;;
esac

TMP="$(mktemp -d /tmp/binate_e2e_fmt_os_args.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# Fixture: print the argument count via %d, then each ARGUMENT (Args()[1..]) via %s
# — the element type is `readonly @[]readonly char`, the exact case that used to
# render `%!?(unknown)`.  Element 0 (the path-dependent program name) is not printed.
cat > "$TMP/fmt_os_args.bn" <<'EOF'
package "main"

import "pkg/std/os"
import "pkg/stdx/fmt"

func main() {
	var a @[]readonly @[]readonly char = os.Args()
	fmt.Printf("argc=%d\n", len(a))
	for i := 1; i < len(a); i++ {
		fmt.Printf("[%s]\n", a[i])
	}
}
EOF

# ----- Build gen1 (a native, checkout-source compiler). -----
# The BUILDER (bnc) compiles cmd/bnc (checkout source); the -I/-L resolve cmd/bnc's
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
ARGS_BIN="$TMP/fmt_os_args-bin"
compile_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$ARGS_BIN" "$TMP/fmt_os_args.bn" 2>&1) || true
if [ ! -x "$ARGS_BIN" ]; then
    echo "FAIL: Binate compile of the fmt-os.Args fixture failed" >&2
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

# fmt renders each real os.Args() element (`readonly @[]readonly char`) as its text,
# not `%!?(unknown)`.  argc counts argv[0] too, so three arguments give argc=4.
WITH_ARGS="argc=4
[alpha]
[beta]
[gamma]"
NO_ARGS="argc=1"
# An EMPTY argument (`""`) still surfaces as a present element that fmt renders as
# `[]` (len 0) — not dropped, not `%!?(unknown)`.
EMPTY_ARG="argc=4
[alpha]
[]
[gamma]"

# (a) compiled native binary: argv[1..] are seen directly (no host, no `--`).
check "compiled/with-args"  "$WITH_ARGS" "$("$ARGS_BIN" alpha beta gamma 2>&1)"
check "compiled/no-args"    "$NO_ARGS"   "$("$ARGS_BIN" 2>&1)"
check "compiled/empty-arg"  "$EMPTY_ARG" "$("$ARGS_BIN" alpha '' gamma 2>&1)"

# (b) cmd/bni interpreting the fixture: the program's args come after `--`, and
# cmd/bni installs them (via os.SetArgs) so os.Args() surfaces them.
check "interp/with-args" "$WITH_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/fmt_os_args.bn" -- alpha beta gamma 2>&1)"
check "interp/no-args"   "$NO_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/fmt_os_args.bn" 2>&1)"
check "interp/empty-arg" "$EMPTY_ARG" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/fmt_os_args.bn" -- alpha '' gamma 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
