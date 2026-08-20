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
# The fixture asserts element 0 (the program-name slot) is PRESENT (non-empty),
# then prints len(Args()) and the arguments (Args()[1..]).  It does not print
# element 0's CONTENT: that is the program path, which differs between the
# compiled-binary run (the binary's path) and the interpreted run (the fixture
# path cmd/bni installs via os.SetArgs), so a cross-path check must skip it.  Both
# paths now populate it: the hosted Binate entry (pkg/builtins/startup._entry, the
# c_export'd `main`) captures the real argv[0] when compiled, and cmd/bni's
# os.SetArgs supplies it when interpreted.  len and the argument elements are
# identical either way.
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
    *) echo "SKIP: os-args unsupported on $(uname -s)"; exit 0 ;;
esac

TMP="$(mktemp -d /tmp/binate_e2e_os_args.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# Fixture: assert element 0 (the program-name slot) is present (non-empty), then
# print the argument count and each ARGUMENT (Args()[1..]) wrapped in brackets.
# Element 0's content is skipped (it is the path-dependent program name), but its
# presence pins that the entry captured argv[0] rather than leaving it empty.
cat > "$TMP/os_args.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/std/os"

func main() {
	var a @[]readonly @[]readonly char = os.Args()
	if len(a) > 0 && len(a[0]) > 0 {
		testing.Println("argv0=present")
	} else {
		testing.Println("argv0=absent")
	}
	testing.Println(len(a))
	for i := 1; i < len(a); i++ {
		testing.Print("[")
		testing.Print(a[i])
		testing.Println("]")
	}
}
EOF

# ----- Resolve a gen1 (native, checkout-source) compiler. -----
# resolve-gen1.sh builds+caches gen1 (the BUILDER compiling checkout cmd/bnc) once
# per tree state, so a full e2e run builds it once and shares it across tests
# rather than each test rebuilding its own.
GEN1_BNC="$("$BINATE_DIR/scripts/resolve-gen1.sh")"

# Common checkout -I/-L (fixture and cmd/bni both link against the current stdlib).
CK_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CK_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# ----- Build the fixture (native) and cmd/bni (native), both via gen1. -----
ARGS_BIN="$TMP/os_args-bin"
compile_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" \
    --build-dir "$BUILD_DIR" -o "$ARGS_BIN" "$TMP/os_args.bn" 2>&1) || true
if [ ! -x "$ARGS_BIN" ]; then
    echo "FAIL: Binate compile of the os.Args fixture failed" >&2
    echo "$compile_log" | sed 's/^/  /' >&2
    exit 1
fi
BNI_BIN="$TMP/bni-bin"
bni_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" \
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

# Every run leads with argv0=present: both the compiled entry and cmd/bni populate
# the program-name slot (element 0), so it is never the empty placeholder.
WITH_ARGS="argv0=present
4
[alpha]
[beta]
[gamma]"
NO_ARGS="argv0=present
1"
# An EMPTY argument (`""`) must still surface as a present element that prints as
# `[]` (len 0).  The compiled entry borrows argv in place (pkg/builtins/startup._entry),
# and a zero-length arg must stay the canonical empty slice — this pins that an
# empty arg flows through the borrow path at all (element count includes it, and
# it renders empty, not dropped or garbled).
EMPTY_ARG="argv0=present
4
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
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" -main-file "$TMP/os_args.bn" -- alpha beta gamma 2>&1)"
check "interp/no-args"   "$NO_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" -main-file "$TMP/os_args.bn" 2>&1)"
check "interp/empty-arg" "$EMPTY_ARG" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" -main-file "$TMP/os_args.bn" -- alpha '' gamma 2>&1)"

# (c) implicit target: a bare positional names the main package (no -main-file),
# and flag parsing stops there — so the args (even flag-looking or empty ones)
# reach the program WITHOUT a `--`.  This is the `bni script.bn args…` / shebang
# form.
check "interp/implicit-file" "$WITH_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/os_args.bn" alpha beta gamma 2>&1)"
check "interp/implicit-empty-arg" "$EMPTY_ARG" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/os_args.bn" alpha '' gamma 2>&1)"

# (d) implicit DIRECTORY main package (auto-detected dir vs file): the same
# program as <dir>/main.bn, run via a bare directory positional.  argv[0] is the
# directory path, which the program skips like any argv[0].
mkdir -p "$TMP/argsdir"
cp "$TMP/os_args.bn" "$TMP/argsdir/main.bn"
check "interp/implicit-dir" "$WITH_ARGS" \
    "$("$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/argsdir" alpha beta gamma 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
