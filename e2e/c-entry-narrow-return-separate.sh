#!/bin/sh
# e2e/c-entry-narrow-return-separate.sh — SEPARATE-COMPILATION parity for the
# __c_entry narrow-return extension.
#
# The sibling e2e/c-entry-narrow-return.sh compiles the callback and its
# __c_entry use TOGETHER (whole program) and runs it.  This test checks the
# property that whole-program run cannot: that a callback package compiled in its
# OWN `bnc --pkg` invocation — with NO visibility of any __c_entry use of it —
# still emits the C-ABI-correct (sign/zero-extended) narrow return.  That is what
# makes separate compilation have PARITY with whole-program: `__c_entry(cbpkg.f)`
# in another package cannot influence cbpkg's own object, so cbpkg's object must
# be correct on its own.
#
# The check is static (grep the isolated `--emit-llvm` output) rather than a
# link+run, because:
#   - the property being verified is exactly "the isolated object carries the
#     signext/zeroext return attribute" — a use-site-marking fix would emit plain
#     `define iN` here;
#   - the generic "separately-compiled objects link and run" property is already
#     covered by e2e/separate-compilation.sh, and the whole-program __c_entry run
#     by e2e/c-entry-narrow-return.sh.
#
# Verified while writing: the use-site-marking predecessor emitted `define i8
# @bn_..._RetI8` (no signext) here; the unconditional extension emits
# `define signext i8 ...` / `define zeroext i8 ...`.
#
# Uses a gen1 bnc built from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_centry_sep.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- a callback package `cbpkg` with narrow returns; NO __c_entry use here -----
mkdir -p "$TMP/if" "$TMP/im/cbpkg"
cat > "$TMP/if/cbpkg.bni" <<'EOF'
package "cbpkg"

// Narrow-return callbacks.  Each truncates a wider argument, so the return
// register carries dirty upper bits unless the callee sign/zero-extends the
// sub-int return.  A __c_entry use of these lives in OTHER packages only.
func RetI8(x int) int8
func RetI16(x int) int16
func RetU8(x int) uint8
EOF
cat > "$TMP/im/cbpkg/lib.bn" <<'EOF'
package "cbpkg"

func RetI8(x int) int8   { return cast(int8, x) }
func RetI16(x int) int16 { return cast(int16, x) }
func RetU8(x int) uint8  { return cast(uint8, x) }
EOF

echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed"
    echo "$gen1_log" | tail -5
    exit 1
fi

IFACE="$TMP/if:$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$TMP/im:$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# --- compile cbpkg in ISOLATION (--pkg) and emit its LLVM ----------------------
if ! "$GEN1" -I "$IFACE" -L "$IMPL" --pkg cbpkg --emit-llvm > "$TMP/cbpkg.ll" 2>"$TMP/ll.err"; then
    echo "FAIL: --pkg cbpkg --emit-llvm failed"
    head -5 "$TMP/ll.err"
    exit 1
fi

# The real callee defines are `@bn_..._RetX(` (the `@__shim...` function-value
# wrappers are a different symbol).  Each narrow return must be extended.
fails=0
check() {  # <return-name> <expected-attr-and-type>
    if grep -Eq "define $2 @bn_[0-9A-Za-z_]*$1\(" "$TMP/cbpkg.ll"; then
        echo "PASS: isolated cbpkg.$1 -> define $2"
    else
        echo "FAIL: isolated cbpkg.$1 lacks 'define $2' (separate compile did not extend the return)"
        grep -nE "define [a-z0-9 ]*@bn_[0-9A-Za-z_]*$1\(" "$TMP/cbpkg.ll" | head -2
        fails=$((fails + 1))
    fi
}
check RetI8  "signext i8"
check RetI16 "signext i16"
check RetU8  "zeroext i8"

echo ""
if [ "$fails" -ne 0 ]; then
    echo "=== Summary: $fails failed ==="
    exit 1
fi
echo "=== Summary: separate-compilation narrow-return parity holds ==="
exit 0
