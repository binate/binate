#!/bin/sh
# e2e/bni-only-var-undefined.sh — A package with only a `.bni` (spec §16.1) declares
# its vars extern: a `.bni` `var` only declares the variable, and its storage is the
# implementation's (decl.var.extern, §16.5) -- a compiled library's, when the package
# ships as interface + library (§16.5.1).  So with no implementation anywhere, a
# program reading such a var must fail loudly instead of reading storage of its own:
#   1. bnc's link reports the var's undefined symbol and exits non-zero;
#   2. bni stops with "nothing in the program defines the package variable
#      pkg/solo.V" and exits non-zero.
#
# bnc is a gen1 (BUILDER -> gen1) and bni is built by it, as in e2e/bni-nil-check.sh.
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnionlyvar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Build gen1 bnc (BUILDER -> gen1) and bni with it -----
echo "Building gen1 bnc and bni..."
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR" --prepend "$BINATE_DIR/ifaces/toolchain")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --build-dir "$GEN1_DIR/build" \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc" 2>&1)
if [ ! -x "$GEN1_BNC" ]; then
    echo "FAIL: gen1 build failed:"
    echo "$gen1_log"
    exit 1
fi

build_log=$("$GEN1_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --build-dir "$BUILD_DIR" \
    -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1)
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: bni build failed:"
    echo "$build_log"
    exit 1
fi

# ----- Fixture: pkg/solo has only a .bni declaring `var V int`; main reads it. -----
SRC="$TMP/src"
mkdir -p "$SRC/pkg"
cat > "$SRC/pkg/solo.bni" <<'EOF'
package "pkg/solo"

// V is declared, but nothing defines it.
var V int
EOF
cat > "$SRC/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/solo"

func main() {
	testing.Println(solo.V)
}
EOF
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$SRC")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$SRC")"

FAILS=0

# ----- 1. bnc: the link fails, naming the var's symbol (bn_G…solo…V). -----
mkdir -p "$TMP/b1"
bnc_out=$(cd "$SRC" && "$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b1" \
    -o "$TMP/prog" main.bn 2>&1)
bnc_rc=$?
if [ "$bnc_rc" -eq 0 ]; then
    echo "FAIL: bnc built a program reading a var nothing defines (it printed: $("$TMP/prog" 2>&1))"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bnc_out" | grep -q 'bn_G[0-9_]*pkg4_solo1_1_V'; then
    echo "FAIL: bnc failed, but not on the var's undefined symbol:"
    printf '%s\n' "$bnc_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bnc's link reports the undefined var"
fi

# ----- 2. bni: the VM stops, naming the var. -----
bni_out=$(cd "$SRC" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" main.bn 2>&1)
bni_rc=$?
if [ "$bni_rc" -eq 0 ]; then
    echo "FAIL: bni ran a program reading a var nothing defines (it printed: $bni_out)"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bni_out" |
        grep -q 'nothing in the program defines the package variable pkg/solo.V'; then
    echo "FAIL: bni failed, but not naming the var:"
    printf '%s\n' "$bni_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bni reports the undefined var"
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
