#!/bin/sh
# e2e/dispatch-seam-narrow.sh — End-to-end test that a NARROW scalar crossing the
# func-value DISPATCH SEAM between different code producers is canonicalized, so a
# native consumer that reads the full register sees the right value.
#
# The dispatch convention (docs/abi/03-dispatch-convention.md §3.3) lets a producer
# pass a narrow scalar in a dispatch slot with only its low bits guaranteed — a
# consumer "shall not rely on a narrow slot's high bits".  The LLVM backend does
# exactly that: it passes a bare iN slot (no signext/zeroext).  A native callee, by
# contrast, keeps every value 64-bit-canonical and reads its register param at full
# width (a bool test / narrow compare is a 64-bit op).  So a native func-value SHIM
# must re-extend an incoming narrow slot before calling the underlying, and a native
# seam CALLER must re-canonicalize a narrow shim RESULT.  Before the fix the native
# shims/collectors forwarded the slot/result verbatim, so dirty high bits from an
# LLVM producer reached the native consumer and flipped a compare.
#
# This can only arise CROSS-PRODUCER (a pure-native or VM<->native program keeps
# every value canonical), so the test builds a MIXED-BACKEND program: package
# `seam/nat` is compiled with `--backend native`, package `seam/lv` and `main` with
# the default LLVM backend, then linked together (each package to its own object,
# then linked — the separate-compilation path).  A func value flows across the
# backend boundary in each direction:
#   * ARG direction:  LLVM `main` marshals a dirty-upper int32 into the dispatch
#     slot and calls a func value whose shim + callee are NATIVE.  A dirty value is
#     forced with an opaque C source (`dirty64`, an optimization barrier) truncated
#     to int32 (a no-op `trunc` that leaves the register's high bits dirty).
#   * RESULT direction:  native `nat.CheckResult` collects a dirty-upper int32
#     RESULT from an LLVM shim.  (Only the x64 native seam caller lacked this;
#     aarch64/arm32 already canonicalized results.)
# The native callee decides on the FULL value, so a dirty high half flips its answer.
#
# Correct output is "111" then "1"; a shim that does not re-extend prints "222", and
# an x64 seam caller that does not re-canonicalize the result prints "0".
#
# The native part self-skips if the host's native backend can't build this program.
# Uses a gen1 bnc built from current source.  Auto-discovered by the e2e runner;
# skips if no C compiler.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_seam.XXXXXX")"
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

WANT="$(printf '111\n1')"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "dispatch-seam-narrow (no C compiler '$CLANG' available)"
    summary
fi

# --- the program: two importable packages + main --------------------------
mkdir -p "$TMP/iface/seam" "$TMP/impl_nat/seam/nat" "$TMP/impl_lv/seam/lv" "$TMP/src"

cat > "$TMP/iface/seam/nat.bni" <<'EOF'
package "seam/nat"

// Callee decides on the FULL value of x; the native backend compiles `x == 5`
// as a full-width compare, so dirty upper bits in a narrow arg flip the result.
func Callee(x int32) int
// MakeArgFV returns a func value whose vtable/shim are NATIVE (built in this
// package's object) — exercises the native SHIM's incoming-arg handling.
func MakeArgFV() @func(int32) int
// CheckResult is a NATIVE seam caller: it dispatches fv() and decides on the
// full value of the narrow result.
func CheckResult(fv @func() int32) int
EOF
cat > "$TMP/impl_nat/seam/nat/nat.bn" <<'EOF'
package "seam/nat"

func Callee(x int32) int {
	if x == 5 {
		return 111
	}
	return 222
}

func MakeArgFV() @func(int32) int {
	return Callee
}

func CheckResult(fv @func() int32) int {
	var r int32 = fv()
	if r == 5 {
		return 1
	}
	return 0
}
EOF

cat > "$TMP/iface/seam/lv.bni" <<'EOF'
package "seam/lv"

// CalleeR returns a dirty-upper int32 (low 32 bits = 5).
func CalleeR() int32
// MakeResultFV returns a func value whose vtable/shim are LLVM (built in this
// package's object) — exercises the native seam caller's RESULT collection.
func MakeResultFV() @func() int32
EOF
cat > "$TMP/impl_lv/seam/lv/lv.bn" <<'EOF'
package "seam/lv"

// trunc32 (a C truncating callee fed a dirty 64-bit value) leaves the return
// register non-canonical per the platform ABI; the LLVM func-value shim returns
// that i32 with the dirty upper bits still present.
func CalleeR() int32 {
	var dirty int64 = __c_call("dirty64", int64)
	return __c_call("trunc32", int32, dirty)
}

func MakeResultFV() @func() int32 {
	return CalleeR
}
EOF

cat > "$TMP/src/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "seam/nat"
import "seam/lv"

func main() {
	// ARG direction: an OPAQUE dirty int64 (from C, so clang can't fold it),
	// truncated to int32 (a no-op that leaves the register's high bits dirty)
	// and passed straight into the NATIVE func value's dispatch slot.
	var w int64 = __c_call("dirty64", int64)
	var argFV @func(int32) int = nat.MakeArgFV()
	testing.Println(argFV(cast(int32, w)))       // want 111; native-shim bug -> 222

	// RESULT direction: native CheckResult collects a dirty-upper int32 result
	// from an LLVM shim.
	var resFV @func() int32 = lv.MakeResultFV()
	testing.Println(nat.CheckResult(resFV))      // want 1; x64 seam-caller bug -> 0
}
EOF

# --- the C dirt source (an optimization barrier) --------------------------
cat > "$TMP/dirt.c" <<'EOF'
/* trunc32: return its arg truncated to int (the low 32 bits).  Per the platform
 * ABI the callee may leave the return register's upper bits dirty, so feeding a
 * dirty-upper 64-bit value yields a genuinely non-canonical int32 return. */
int trunc32(long long x) { return (int)x; }
/* dirty64: an opaque source of a value whose low 32 bits are 5 and whose upper
 * 32 bits are garbage; opaque (a separate TU) so the optimizer can't fold it. */
long long dirty64(void) { return (long long)0xBEEF000000000005LL; }
EOF

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    fail "gen1 bnc build failed" "$(echo "$gen1_log" | tail -5)"
    summary
fi

CKI="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CKL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# synth_memzero <objdir> <out.o>: if any object under <objdir> has an UNDEFINED
# rt.MemZero (the arches — currently aarch64 — whose Binate rt.MemZero body is
# #[build]-gated off in favor of a hand-written asm one that bnc's OWN linker
# injects, which a raw cross-backend clang link bypasses), synthesize a trivial
# byte-loop rt.MemZero with the EXACT undefined symbol name extracted from the
# object, assemble it with clang, and echo the object path.  Echoes "" when no
# MemZero is missing (e.g. x64, whose portable Binate body is compiled in).
synth_memzero() {
    _od="$1"; _out="$2"
    _sym="$(find "$_od" -name '*.o' -exec nm {} \; 2>/dev/null \
            | awk '/ U / && /MemZero/ { print $2; exit }')"
    [ -z "$_sym" ] && { echo ""; return; }
    case "$(uname -m)" in
        arm64|aarch64) : ;;
        *) echo ""; return ;;   # only the aarch64 memzero body is provided here
    esac
    cat > "$TMP/memzero.s" <<EOF2
.text
.globl $_sym
$_sym:
1: cbz x1, 2f
   strb wzr, [x0], #1
   sub x1, x1, #1
   b 1b
2: ret
EOF2
    "$CLANG" -c -o "$_out" "$TMP/memzero.s" 2>/dev/null || { echo ""; return; }
    echo "$_out"
}

# build_mixed <label> <nat-backend-flag>: separate-compile the program with
# seam/nat built under <nat-backend-flag> (either `--backend native` for the real
# cross-backend test, or "" for the all-LLVM control), link, run, and check.
build_mixed() {
    _label="$1"; _natflag="$2"; _required="$3"
    _w="$TMP/$_label"; mkdir -p "$_w/sep" "$_w/main"
    _I="$TMP/iface:$CKI"
    _L="$TMP/impl_nat:$TMP/impl_lv:$CKL"

    _deps="$("$GEN1" -I "$_I" -L "$_L" --list-deps "$TMP/src/main.bn" 2>"$_w/ld.err")"
    if [ -z "$_deps" ]; then
        fail "$_label: --list-deps failed" "$(head -3 "$_w/ld.err")"
        return
    fi
    _n=0
    for _p in $_deps; do
        _n=$((_n + 1)); _d="$_w/sep/p$_n"; mkdir -p "$_d"
        _be=""
        if [ "$_p" = "seam/nat" ]; then _be="$_natflag"; fi
        if ! "$GEN1" -I "$_I" -L "$_L" $_be -O2 --build-dir "$_d" --pkg "$_p" >"$_d/log" 2>&1 \
                || [ -z "$(ls "$_d"/*.o 2>/dev/null)" ]; then
            if [ "$_p" = "seam/nat" ] && [ "$_required" -eq 0 ]; then
                skip "$_label: native backend cannot build seam/nat on this host"
            else
                fail "$_label: separate compile of '$_p' failed" "$(tail -3 "$_d/log")"
            fi
            return
        fi
    done
    if ! "$GEN1" -I "$_I" -L "$_L" -O2 --build-dir "$_w/main" -c "$TMP/src/main.bn" \
            >"$_w/main/log" 2>&1 || [ ! -f "$_w/main/main.o" ]; then
        fail "$_label: could not compile main.o" "$(tail -5 "$_w/main/log")"
        return
    fi
    if ! "$CLANG" -c -O2 -o "$_w/dirt.o" "$TMP/dirt.c" 2>"$_w/cc.err"; then
        fail "$_label: C dirt source compile failed" "$(head -3 "$_w/cc.err")"
        return
    fi
    _memobj="$(synth_memzero "$_w/sep" "$_w/memzero.o")"
    _sep="$(find "$_w/sep" -name '*.o' | tr '\n' ' ')"
    if ! "$CLANG" -w -o "$_w/run" "$_w/main/main.o" $_sep "$_w/dirt.o" $_memobj \
            2>"$_w/link.err" || [ ! -x "$_w/run" ]; then
        fail "$_label: link failed" "$(head -6 "$_w/link.err")"
        return
    fi
    _got="$("$_w/run" 2>&1)"
    if [ "$_got" = "$WANT" ]; then
        pass "$_label: narrow dispatch-seam values canonicalized ('$(echo "$_got" | tr '\n' ' ')')"
    else
        fail "$_label: dispatch-seam narrow-value mismatch" \
             "got:  $(echo "$_got" | tr '\n' ' ')" \
             "want: $(echo "$WANT" | tr '\n' ' ')"
    fi
}

# The mixed-backend case is the meaningful one (self-skips if native can't build);
# the all-LLVM control pins that the program is correct when both sides agree.
build_mixed "mixed" "--backend native" 0
build_mixed "llvm-control" "" 1

summary
