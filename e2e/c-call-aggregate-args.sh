#!/bin/sh
# e2e/c-call-aggregate-args.sh — End-to-end test that AGGREGATE and MANAGED
# `__c_call` arguments cross the C ABI boundary correctly, with a real C callee.
#
# `__c_call("sym", Ret, args...)` infers the C parameter type of each argument
# from the argument's OWN Binate type and marshals it per the platform C ABI
# (§7.13) plus the ordinary parameter-ownership contract (§18.5 mem.param).  This
# test drives, through a real C callee, the argument shapes beyond the original
# scalar/pointer set:
#
#   - a SMALL struct by value (<=16 bytes): coerced to the C small-struct register
#     form (`[N x iW]`).  This is the case the LLVM backend miscompiled before the
#     coercion was wired in — it passed a bare first-class `%struct` value, which
#     LLVM lowered as a single register, so `addp(Point{20,22})` read 20 instead
#     of 42.  The fix reuses the regular call path's C-ABI marshaling.
#   - a LARGE struct by value (>16 bytes): passed via the memory class (`byval`
#     pointer to a caller-owned copy).
#   - a RAW SLICE `*[]int32`: its two-word `{int32*, ptrdiff_t}` header maps to a
#     C `struct { int32_t* data; ptrdiff_t len; }` by value.
#   - a MANAGED POINTER `@T` as a BORROW: C receives the pointer to the object's
#     data and reads a field DURING the call.  mem.param makes a `@T` argument a
#     borrow — the caller keeps its reference and the callee (here, C) must not
#     retain the pointer past the call without a manual RefInc.  Reading a field
#     in-call needs no refcount traffic, so this exercises the borrow contract
#     directly.
#
# Every callee returns a value that sums to 42, so the whole run prints
# "42" repeated six times on success; a wrong ABI coercion for any argument perturbs one
# number.
#
# Both backends are checked: LLVM (always) and native (--backend native, which on
# the aa64/x64 CI hosts emits + links this program; self-skips if the host's
# native backend can't build it).  Built at -O2 so the LLVM small-struct case
# runs through the optimizer that made the original miscompile visible.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_ccagg.XXXXXX")"
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

# Each callee's result sums to 42; the run prints one line per call.
WANT="42
42
42
42
42
42
42"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "c-call-aggregate-args (no C compiler '$CLANG' available)"
    summary
fi

# --- the C callees: one per argument shape ------------------------------------
cat > "$TMP/cagg.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>

/* SMALL struct by value (<=16 bytes): register-coerced to [2 x i32] on the SysV /
 * AAPCS64 ABIs.  addp(Point{20,22}) must read 42; a bare-struct-value miscompile
 * reads only the first field (20). */
struct Point { int32_t x; int32_t y; };
int32_t addp(struct Point p) { return p.x + p.y; }

/* LARGE struct by value (>16 bytes): memory class -> byval pointer to a copy. */
struct Big { int64_t a, b, c; };
int64_t sumbig(struct Big b) { return b.a + b.b + b.c; }

/* TWO large structs by value: on x86_64 SysV each is MEMORY class (bytes on the
 * outgoing stack).  A single-arg case can pass by accident on x64 (the one arg
 * aliases top-of-stack); two args do not, so this is the case that actually
 * catches a wrong >16-byte C ABI (pointer-in-register instead of byval). */
int64_t sum2big(struct Big x, struct Big y) {
    return x.a + x.b + x.c + y.a + y.b + y.c;
}

/* A ≤16-byte aggregate arg placed AFTER a >16-byte one, under register pressure:
 * on x86_64 SysV the >16 `big` is MEMORY class (0 registers), so `two` (16 bytes)
 * must ride the remaining GP regs (R8:R9), NOT the stack.  If the caller models
 * the >16 aggregate as consuming a register (Binate's internal convention), it
 * over-advances the register cursor and wrongly spills `two` to the stack, and
 * this callee reads garbage from R8:R9.  1+2+3+4 + (5+6+7) + (6+8) = 42. */
struct Two { int64_t x, y; };
int64_t mix(int32_t a, int32_t b, int32_t c, int32_t d, struct Big big, struct Two two) {
    return (int64_t)a + b + c + d + big.a + big.b + big.c + two.x + two.y;
}

/* VOID callee taking a large struct: a void __c_call gets no SSA result, so two
 * of them with aggregate args must still get DISTINCT per-arg scratch slots
 * (else the LLVM backend emits duplicate `%v-1.bv0` names -> compile failure).
 * g_sink lets the Binate side read back the LAST sink's value to prove the bytes
 * crossed correctly too. */
static int64_t g_sink = 0;
void sink_big(struct Big b) { g_sink = b.a + b.b + b.c; }
int64_t read_sink(void) { return g_sink; }

/* RAW SLICE *[]int32 -> { int32_t* data; ptrdiff_t len } by value. */
struct I32Slice { int32_t* data; ptrdiff_t len; };
int32_t sumslice(struct I32Slice s) {
    int32_t t = 0;
    for (ptrdiff_t i = 0; i < s.len; i++) t += s.data[i];
    return t;
}

/* MANAGED POINTER @TData borrow: C gets a pointer to the object's data (the
 * refcount header sits at a negative offset, invisible here) and reads field v
 * during the call.  A borrow needs no refcount traffic. */
struct TData { int32_t v; };
int32_t readv(struct TData* p) { return p->v; }
EOF

# --- the Binate program: one __c_call per argument shape ----------------------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

type Point struct { x int32; y int32 }
type Big struct { a int64; b int64; c int64 }
type Two struct { x int64; y int64 }
type TData struct { v int32 }

func main() {
	// small struct by value (register-coerced): 20 + 22 = 42
	var p Point
	p.x = cast(int32, 20)
	p.y = cast(int32, 22)
	testing.Println(cast(int, __c_call("addp", int32, p)))

	// large struct by value (byval): 10 + 15 + 17 = 42
	var big Big
	big.a = cast(int64, 10)
	big.b = cast(int64, 15)
	big.c = cast(int64, 17)
	testing.Println(cast(int, __c_call("sumbig", int64, big)))

	// TWO large structs by value: (1+2+3) + (10+12+14) = 42.  The case a
	// single-arg test can't catch on x86_64.
	var b1 Big
	b1.a = cast(int64, 1)
	b1.b = cast(int64, 2)
	b1.c = cast(int64, 3)
	var b2 Big
	b2.a = cast(int64, 10)
	b2.b = cast(int64, 12)
	b2.c = cast(int64, 14)
	testing.Println(cast(int, __c_call("sum2big", int64, b1, b2)))

	// A ≤16 aggregate arg AFTER a >16 one, under register pressure: on x86_64 the
	// >16 `big` is MEMORY class (0 regs), so `two` must ride R8:R9 — a wrong
	// register-cursor model spills it to the stack and C reads garbage.
	// 1+2+3+4 + (5+6+7) + (6+8) = 42.
	var mbig Big
	mbig.a = cast(int64, 5)
	mbig.b = cast(int64, 6)
	mbig.c = cast(int64, 7)
	var mtwo Two
	mtwo.x = cast(int64, 6)
	mtwo.y = cast(int64, 8)
	testing.Println(cast(int, __c_call("mix", int64,
			cast(int32, 1), cast(int32, 2), cast(int32, 3), cast(int32, 4), mbig, mtwo)))

	// TWO void __c_calls with large-struct args (distinct scratch slots) +
	// read-back of the LAST: 20 + 10 + 12 = 42.
	var s1 Big
	s1.a = cast(int64, 1)
	s1.b = cast(int64, 1)
	s1.c = cast(int64, 1)
	__c_call("sink_big", "void", s1)
	var s2 Big
	s2.a = cast(int64, 20)
	s2.b = cast(int64, 10)
	s2.c = cast(int64, 12)
	__c_call("sink_big", "void", s2)
	testing.Println(cast(int, __c_call("read_sink", int64)))

	// raw slice *[]int32 (2-word header): 10 + 20 + 12 = 42
	var arr [3]int32
	arr[0] = cast(int32, 10)
	arr[1] = cast(int32, 20)
	arr[2] = cast(int32, 12)
	var s *[]int32 = arr[0:3]
	testing.Println(cast(int, __c_call("sumslice", int32, s)))

	// managed pointer @TData borrow: C reads v = 42 during the call
	var t @TData = make(TData)
	t.v = cast(int32, 42)
	testing.Println(cast(int, __c_call("readv", int32, t)))
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
#   Compile the C callees for the HOST arch, compile+link the Binate program
#   against them with the given backend, run, and check the output.  required=1 ->
#   a compile failure is a hard FAIL (LLVM); required=0 -> a native backend that
#   can't build this program on this host SKIPs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -c -O2 -o "$work/cagg.o" "$TMP/cagg.c" 2>"$work/cc.err"; then
        fail "$label: C callee compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --link-after-objs "$work/cagg.o" --build-dir "$work" \
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
        pass "$label: aggregate + managed __c_call args crossed the C ABI correctly"
    else
        fail "$label: aggregate __c_call argument mismatch" \
             "got:  $(echo "$got" | tr '\n' ' ')" \
             "want: six 42s (a wrong ABI coercion perturbs one number)"
    fi
}

check_backend "llvm" "-O2" 1
check_backend "native" "--backend native -O2" 0

# --- arm32-linux leg (AAPCS32) --------------------------------------------
# arm32 passes a >16-byte aggregate BY VALUE (coerced [N x iW], split r0-r3 +
# stack) — a THIRD C-ABI shape distinct from x86_64 (byval-on-stack) and aarch64
# (indirect pointer).  Cross-compile the same program for arm32-linux and run it
# under qemu-arm on both backends, when a working arm32 cross-toolchain + qemu are
# present (the Linux CI lane; self-SKIPs on macOS / a partial toolchain, exactly
# like e2e/arm32-toolchain-smoke.sh).  This is the regression guard for the arm32
# split-path frame-reservation fix (a >16 aggregate whose value is a call result
# used to clobber a live spill).
ARM_QEMU="$(command -v qemu-arm-static || command -v qemu-arm || true)"
[ -d /usr/arm-linux-gnueabihf ] && export QEMU_LD_PREFIX=/usr/arm-linux-gnueabihf
arm32_probe() {
    [ -n "$ARM_QEMU" ] || return 1
    echo 'int main(void){return 0;}' \
        | "$CLANG" -target arm-linux-gnueabihf -march=armv7-a -x c - -o "$TMP/_a32probe" 2>/dev/null \
        && "$ARM_QEMU" "$TMP/_a32probe" >/dev/null 2>&1
}

# check_arm32 <label> <extra-bnc-flags>: cross-compile the C callees for arm32,
# cross-build the Binate program for arm32-linux with the given backend, run under
# qemu-arm, check the output.
check_arm32() {
    label="arm32-$1"; extra="$2"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$CLANG" -target arm-linux-gnueabihf -march=armv7-a -c -o "$work/cagg.o" "$TMP/cagg.c" 2>"$work/cc.err"; then
        fail "$label: arm32 C callee compile failed" "$(head -4 "$work/cc.err")"
        return
    fi
    if ! "$GEN1" -I "$A32_IFACE" -L "$A32_IMPL" --target arm32-linux $extra \
            --link-after-objs "$work/cagg.o" --build-dir "$work" \
            -o "$work/run" "$TMP/main.bn" >"$work/comp.log" 2>&1 \
            || [ ! -x "$work/run" ]; then
        fail "$label: compile/link of the arm32 Binate program failed" \
             "$(tail -5 "$work/comp.log")"
        return
    fi
    got="$("$ARM_QEMU" "$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: aggregate + managed __c_call args crossed the AAPCS32 C ABI correctly"
    else
        fail "$label: arm32 aggregate __c_call argument mismatch" \
             "got:  $(echo "$got" | tr '\n' ' ')" \
             "want: six 42s (a wrong ABI coercion or a clobbered spill perturbs one number)"
    fi
}

if arm32_probe; then
    A32_IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-linux)"
    A32_IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    check_arm32 "llvm" "-O2"
    check_arm32 "native" "--backend native -O2"
else
    skip "arm32: no working arm-linux-gnueabihf cross-toolchain + qemu-arm (skipping the AAPCS32 leg)"
fi

summary
