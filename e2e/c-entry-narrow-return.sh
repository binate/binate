#!/bin/sh
# e2e/c-entry-narrow-return.sh — End-to-end test that a Binate callback handed to
# C via `__c_entry` whose RESULT is a sub-`int` scalar (int8/int16/uint8) extends
# that result per the platform C ABI, so an optimizing C caller reads the correct
# value across the callback boundary.
#
# `__c_entry(f)` yields a C-callable pointer to f.  On the LLVM backend the pointer
# is f's mangled `define` directly (the no-thunk "degenerate" case — the C ABI
# lowers each narrow ARG itself), so f's define IS the C-ABI entry.  A clang caller
# at -O1+ TRUSTS the callee to sign/zero-extend a sub-`int` RETURN (AssertS/Zext)
# and elides its own re-extension — so if f's define lacks the `signext`/`zeroext`
# return attribute, the caller reads dirty upper bits.  bnc gated that attribute on
# `#[c_export]` only, so a __c_entry-ONLY target (not also exported) leaked dirty
# bits: this test's callbacks return int8/int16/uint8 derived from a WIDER argument
# (cast truncation), read at -O2 by a C driver.  Verified while writing: without the
# fix the driver prints `507 130944 456` (the raw untruncated args) instead of
# `-5 -128 200`.  This is the return-side analogue of c-entry-narrow-callback.sh
# (which covers the ARGUMENT side) and the __c_entry analogue of ffi-export.sh's
# #[c_export] narrow-returns driver.
#
# The C driver reads each result as `int` and prints it, so the check runs entirely
# in C at -O2 (no Binate-side re-widening — DarwinPCS extends a narrow return to 32
# bits, not 64).  Binate just hands the three __c_entry pointers to `run_narrow` via
# a void `__c_call`.
#
# Both backends are checked: LLVM (always — the meaningful one, since the bug is
# LLVM-only) and native (--backend native; self-skips if the host's native backend
# can't build this program).  Native is unaffected by construction (full-width
# canonical returns), so its variant just pins that the backends agree.
#
# Uses a gen1 bnc built from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS; skips if no C compiler.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_centry_ret.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }
fail() {
    echo "FAIL: $1"
    FAIL_NAMES="$FAIL_NAMES ${1%% *}"
    shift
    for line in "$@"; do echo "  $line"; done
    FAILS=$((FAILS + 1))
}

summary() {
    echo ""
    echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
    if [ "$FAILS" -ne 0 ]; then
        echo "Failed:$FAIL_NAMES"
        exit 1
    fi
    exit 0
}

# Correct results: each callback truncates its WIDER argument to its narrow return
# and the callee extends it per the C ABI.  Without the fix, the -O2 C caller reads
# the raw untruncated argument (507 / 130944 / 456) instead.
WANT="-5 -128 200"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-entry-narrow-return (no C compiler '$CLANG' available)"
    summary
fi

# --- the C caller: invoke each callback and read its narrow return at -O2 ------
cat > "$TMP/ccall.c" <<'EOF'
#include <stdio.h>
/* Each callback is declared with its TRUE narrow-return prototype and its result
 * is read as int, all inside this -O2 TU: clang trusts the callee's ABI extension
 * (AssertS/Zext) and skips its own re-extension, so an un-extended callee return
 * surfaces as dirty upper bits — a wrong printed value. */
void run_narrow(signed char (*f8)(int), short (*f16)(int), unsigned char (*fu8)(int)) {
    int a = f8(507);       /* trunc 0xFB   -> -5   (signed)   */
    int b = f16(0x1FF80);  /* trunc 0xFF80 -> -128 (signed)   */
    int c = fu8(456);      /* trunc 0xC8   -> 200  (unsigned) */
    printf("%d %d %d\n", a, b, c);
}
EOF

# --- the Binate program: hand the three callbacks to C via __c_entry -----------
cat > "$TMP/main.bn" <<'EOF'
package "main"

// None are #[c_export]; each is reached ONLY through a __c_entry pointer, so its
// define must still carry the C-ABI narrow-return extension.  Each truncates a
// wider argument, so the return register carries dirty upper bits absent the
// signext/zeroext fix.
func retI8(x int) int8   { return cast(int8, x) }
func retI16(x int) int16 { return cast(int16, x) }
func retU8(x int) uint8  { return cast(uint8, x) }

func main() {
	__c_call("run_narrow", "void", __c_entry(retI8), __c_entry(retI16), __c_entry(retU8))
}
EOF

# --- build gen1 bnc from current source ---------------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    fail "gen1 bnc build failed" "$(echo "$gen1_log" | tail -5)"
    summary
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# check_backend <label> <extra-bnc-flags> <required>
#   Compile the C caller (-O2) for the host, compile+link the Binate program with
#   the given backend, run, and check the output.  required=1 -> a compile failure
#   is a hard FAIL (LLVM); required=0 -> a native backend that can't build this
#   program on this host SKIPs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/ccall.o" "$TMP/ccall.c" 2>"$work/cc.err"; then
        fail "$label: C caller compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/ccall.o" --build-dir "$work" \
            -o "$work/run" "$TMP/main.bn" >"$work/comp.log" 2>&1 \
            || [ ! -x "$work/run" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile/link of the Binate program failed" \
                 "$(tail -5 "$work/comp.log")"
        else
            skip "$label: native backend cannot build this program on this host"
        fi
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: __c_entry narrow returns extended correctly ('$got')"
    else
        fail "$label: __c_entry narrow-return mismatch" \
             "got:  $got" \
             "want: $WANT (raw args => the callee did not sign/zero-extend the return)"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

summary
