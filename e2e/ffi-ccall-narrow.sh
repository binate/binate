#!/bin/sh
# e2e/ffi-ccall-narrow.sh — End-to-end test that a Binate __c_call passes a
# sub-`int`-width ARGUMENT to a C callee with the platform C-ABI sign/zero
# extension.  The argument-direction sibling of e2e/ffi-export.sh's narrow-RETURN
# check (both stem from the same signext/zeroext hazard).
#
# A clang callee assumes the CALLER extended a narrow integer/bool argument to
# (at least) `int` width — DarwinPCS on darwin-arm64 mandates it; the de-facto
# clang ABI on x86-64 relies on the signext/zeroext attribute — so at -O2 the
# callee reads the whole register WITHOUT re-extending.  If a __c_call hands it a
# bare (un-extended) i8/i16/i1 whose upper bits are dirty, the callee reads a
# wrong value: a silent miscompile at the C boundary.
#
# Flow (one link unit): a C `main` -> a Binate #[c_export] wrapper (which the C
# side reaches by its C name) -> the wrapper's __c_call back into a C callee
# compiled at -O2.  Each wrapper truncates a WIDE int32 (nonzero upper bits) to a
# narrow type before the __c_call, so an un-extended argument surfaces as the raw
# wide value; the -O2 callee returns the narrow param straight back as `int`,
# trusting the caller's extension.
#
# Both backends are checked: LLVM (default, required) and NATIVE (--backend
# native, self-skips if the host backend can't emit the facade).  Native passes
# narrow args as canonical full-width values, so it over-satisfies the C ABI and
# must pass when it runs.
#
# Uses a gen1 bnc built from current source (the shipped BUILDER predates
# #[c_export] / __c_call and would reject the facade).  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS; needs only a host C compiler
# (no cross-toolchain / qemu — it runs on the host arch).  Exit 0 on pass.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: ffi-ccall-narrow (no C compiler '$CLANG' available)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_ccall.XXXXXX")"
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

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed:"
    echo "$gen1_log" | tail -20
    exit 1
fi
IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# --- the __c_call facade: narrow-arg wrappers -----------------------------
# Each wrapper is exported under a C name (so the driver's `main` calls it) and
# forwards a narrow slice of a wide int32 to a C callee via __c_call.  Truncating
# a wide value means the natural codegen leaves nonzero upper bits in the arg
# register unless the __c_call applies the C-ABI extension.
mkdir -p "$TMP/if" "$TMP/im/ccnarrow"
cat > "$TMP/if/ccnarrow.bni" <<'EOF'
package "ccnarrow"
EOF
cat > "$TMP/im/ccnarrow/lib.bn" <<'EOF'
package "ccnarrow"

#[c_export("bn_take_i8")]
func takeI8(base int32) int32 { return __c_call("ctake_i8", int32, cast(int8, base)) }

#[c_export("bn_take_i16")]
func takeI16(base int32) int32 { return __c_call("ctake_i16", int32, cast(int16, base)) }

#[c_export("bn_take_u8")]
func takeU8(base int32) int32 { return __c_call("ctake_u8", int32, cast(uint8, base)) }

#[c_export("bn_take_bool")]
func takeBool(base int32) int32 { return __c_call("ctake_bool", int32, base != 0) }
EOF

# --- the C driver: main + the -O2 callees that trust caller-extension -----
# The callees are compiled at -O2 so clang omits its own re-extension of the
# narrow param and reads the register as already extended to 32 bits (the ABI
# contract the __c_call must satisfy).  `main` calls the Binate wrappers by their
# C names with base values whose upper bits are nonzero above the narrow field.
cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>

/* -O2 callees: each returns the narrow param straight back as int/unsigned,
   trusting the caller sign/zero-extended it to 32 bits. */
int      ctake_i8  (signed char x)   { return x; }
int      ctake_i16 (short x)         { return x; }
unsigned ctake_u8  (unsigned char x) { return x; }
int      ctake_bool(_Bool x)         { return x ? 1 : 0; }

extern int bn_take_i8  (int);
extern int bn_take_i16 (int);
extern int bn_take_u8  (int);
extern int bn_take_bool(int);

int main(void) {
    int r8   = bn_take_i8  (507);      /* 0x1FB   -> int8  0xFB   = -5    */
    int r16  = bn_take_i16 (130772);   /* 0x1FED4 -> int16 0xFED4 = -300  */
    int ru8  = bn_take_u8  (456);      /* 0x1C8   -> uint8 0xC8   = 200   */
    int rb   = bn_take_bool(512);      /* 0x200 (low byte 0) but != 0 -> true = 1 */
    printf("%d %d %d %d\n", r8, r16, ru8, rb);
    return 0;
}
EOF
WANT="-5 -300 200 1"

# check_ccall_narrow <label> <extra-bnc-flags> <required>
#   Compile the facade with the given backend flags, link the -O2 C driver
#   (which supplies both `main` and the callees) against the object, run, and
#   check.  required=1 -> a compile failure is a hard FAIL; required=0 -> a
#   compile producing no object SKIPs (host native backend may not cover the
#   facade), but a produced-but-broken object still FAILs at link/run.
check_ccall_narrow() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ccnarrow >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ccnarrow.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ccnarrow) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w -O2 "$TMP/driver.c" "$work/ccnarrow.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of -O2 C driver + facade object failed" "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: __c_call sign/zero-extends narrow args; -O2 C callee reads them: '$got'"
    else
        fail "$label: narrow-arg output mismatch (got '$got', want '$WANT')"
    fi
}

# LLVM is required (the bug lived on the LLVM __c_call path); native self-skips
# when the host backend can't emit the facade, but must pass when it runs (its
# canonical full-width args over-satisfy the C ABI).
check_ccall_narrow "llvm"   ""                 1
check_ccall_narrow "native" "--backend native" 0

summary
