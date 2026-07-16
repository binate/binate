#!/bin/sh
# e2e/c-subword-return.sh — End-to-end test that a Binate program correctly reads
# a SUB-WORD integer value returned by a C function across the ABI boundary.
#
# A C callee follows the platform ABI for a sub-word return: it guarantees only
# the LOW bits of the return register.  On AAPCS64 clang extends a `signed char`
# return to just the 32-bit w0 (`mov w0,#-1` -> x0 = 0x00000000FFFFFFFF), leaving
# bits 63:32 unspecified; on SysV-AMD64 the upper bits of RAX are undefined.  Every
# native Binate VALUE, by contrast, is kept 64-bit-canonical (a Binate `int8 -1` is
# 0xFFFF..FF).  So a native CALLER must re-extend a foreign sub-word return before
# using it directly.  x64 always did (movsx/movzx); the aa64 / arm32 backends did
# NOT, so a foreign `signed char`/`short`/`int` return with non-canonical upper bits
# used in a comparison read the wrong value — `if c_signed_char() == -1` was false on
# aarch64.  This test guards that fix: it __c_call's C functions returning a negative
# int8 / int16, a uint8, and a dirty-upper int32 (a truncating callee fed a
# dirty-upper 64-bit value), and checks each is seen at full width.
#
# Both backends are checked: LLVM (always) and native (--backend native, which on
# the aa64/x64 CI hosts emits + links this program; self-skips if the host's native
# backend can't build it).  The bug is native-only, so the native variant is the
# meaningful one; the LLVM variant pins that the two backends agree.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_csub.XXXXXX")"
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

# Each line is 1 iff the sub-word C return was read at full width; last line is the
# widened signed-char value (-5) as a control that the widening path also agrees.
WANT="1
1
1
1
-5"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-subword-return (no C compiler '$CLANG' available)"
    summary
fi

# --- the C callees: sub-word returns, per the platform ABI ----------------
cat > "$TMP/csub.c" <<'EOF'
signed char sc(void)   { return -5; }    /* negative int8  */
short        sh(void)  { return -300; }   /* negative int16 */
unsigned char uc(void) { return 200; }    /* uint8          */
/* Returns its arg truncated to int (the low 32 bits).  Per AAPCS64 the callee may
 * leave the return register's upper 32 bits DIRTY (clang -O2 does — a bare `ret`),
 * so feeding a dirty-upper 64-bit value yields a genuinely non-canonical int32
 * return — the case a clean `return -1;` (which clang lowers as an upper-zeroing
 * `mov w0`) would NOT exercise. */
int trunc32(long long x) { return (int)x; }
EOF

# --- the Binate program: __c_call each, compare / widen -------------------
cat > "$TMP/main.bn" <<'EOF'
package "main"
func main() {
	if __c_call("sc", int8) == cast(int8, -5) { println(1) } else { println(0) }
	if __c_call("sh", int16) == cast(int16, -300) { println(1) } else { println(0) }
	if __c_call("uc", uint8) == cast(uint8, 200) { println(1) } else { println(0) }
	// A dirty-upper int32 return (0xBEEF00000000_0005 truncated -> low 32 = 5): only
	// the low 32 bits are ABI-guaranteed, so the native caller must re-canonicalize
	// before the 64-bit compare, else `== 5` is false on aarch64.
	var hi int64 = cast(int64, 0xBEEF)
	var dirty int64 = (hi << 48) | 5
	if __c_call("trunc32", int32, dirty) == 5 { println(1) } else { println(0) }
	println(cast(int, __c_call("sc", int8)))
}
EOF

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    fail "gen1 bnc build failed" "$(echo "$gen1_log" | tail -5)"
    summary
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
RT="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")"

# check_backend <label> <extra-bnc-flags> <required>
#   Compile the C callee for the HOST arch (which matches both the host-native and
#   the LLVM-host default targets), compile+link the Binate program against it with
#   the given backend, run, and check the output.  required=1 -> a compile failure
#   is a hard FAIL (LLVM); required=0 -> a native backend that can't build this
#   program on this host SKIPs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/csub.o" "$TMP/csub.c" 2>"$work/cc.err"; then
        fail "$label: C callee compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" --runtime "$RT" $extra \
            --link-after-objs "$work/csub.o" --build-dir "$work" \
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
        pass "$label: sub-word C returns read at full width ('$(echo "$got" | tr '\n' ' ')')"
    else
        fail "$label: sub-word C return mismatch" \
             "got:  $(echo "$got" | tr '\n' ' ')" \
             "want: $(echo "$WANT" | tr '\n' ' ')"
    fi
}

check_backend "llvm" "" 1
check_backend "native" "--backend native" 0

summary
