#!/bin/sh
# e2e/ffi-export.sh — End-to-end test that a C program can call a Binate function
# exported via #[c_export("name")] (FFI export, plan-ffi-export-detailed.md).
#
# Builds a small Binate FACADE package whose functions carry #[c_export("...")],
# compiles it to an object with `bnc --pkg`, then compiles + links a C driver
# that calls the exported functions BY THEIR C NAMES (never the mangled bn_
# symbols) and checks the output.  Exercises the three ratified behaviours:
#   - a PUBLIC (.bni-exported) function exported under a C name;
#   - a PRIVATE (non-.bni) function exported under a C name (package-public is
#     NOT required to c_export — a package can expose a private callback);
#   - one function exported under SEVERAL C names.
#
# Both backends are checked: the LLVM path (default, always) and the NATIVE path
# (--backend native, when the host's native backend can emit the facade — else
# that variant self-skips).  So the native second-symbol emission gets real
# link-and-run coverage, not just an in-memory symbol-table assertion.
#
# Beyond the #[c_export] names, the facade also covers MULTI-VALUE returns crossing
# the C boundary two ways: called directly by C name (check_multiret) and reached
# THROUGH a __c_entry callback pointer (check_centry) — both must adapt Binate's
# internal multi-return convention to the platform C struct-return ABI.
#
# The exported functions are PURE COMPUTE (no I/O, no allocation), so the object
# is self-contained: it needs neither runtime I/O shims nor a Binate
# main/runtime, so the C driver owns main() and links the object directly,
# mirroring e2e/separate-compilation.sh.  The .a-archive path (check_library)
# links + inits + calls the whole archive through a C driver.
#
# Uses a gen1 bnc built from the current source: the shipped BUILDER predates
# #[c_export] and would reject it.  Auto-discovered by
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_ffi.XXXXXX")"
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

# Shared arithmetic-export prefix (ffi_add ffi_mul ffi_sub ffi_sub2); each driver
# appends its own tail (the exports it actually calls).
WANT_BASE="42 42 42 99"
# check_backend driver: + ffi_sgn(-5) ffi_sgn(5) ffi_ro(-3) ffi_ro(3)
#   + ffi_stack_sgn(-5 on stack) ffi_stack_sgn(5 on stack)
WANT="$WANT_BASE 1 0 1 0 1 0"

if ! command -v "$CLANG" >/dev/null 2>&1; then
    skip "ffi-export (no C compiler '$CLANG' available)"
    summary
fi

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

# --- the facade package (out-of-tree, in TMP) -----------------------------
mkdir -p "$TMP/if" "$TMP/im/ffiexp"
cat > "$TMP/if/ffiexp.bni" <<'EOF'
package "ffiexp"

func Add(a int, b int) int
func Sub(a int, b int) int
EOF
cat > "$TMP/im/ffiexp/lib.bn" <<'EOF'
package "ffiexp"

// Exported (public) function under one C name.
#[c_export("ffi_add")]
func Add(a int, b int) int { return a + b }

// PRIVATE function (not in the .bni) under a C name — package-public is not
// required to c_export.
#[c_export("ffi_mul")]
func mul(a int, b int) int { return a * b }

// One function exported under SEVERAL C names.
#[c_export("ffi_sub", "ffi_sub2")]
func Sub(a int, b int) int { return a - b }

// A package-level var initializer — set to 40 ONLY when the closure's inits run.
// The --library arm reads it (after bn_init) to prove bn_init actually ran the
// initializers, not just that the symbol linked.  (The --pkg arms never call it.)
var base int = 40

#[c_export("ffi_base")]
func GetBase() int { return base }

// A NON-idempotent init side effect, so the --library arm can prove bn_init runs
// the inits exactly ONCE.  `counter` has no initializer, so __init never resets
// it; the blank-var initializer bumps it once per __init run.  The arm calls
// bn_init() TWICE and asserts counter == 1 — a missing run-once guard (inits
// re-running) would show counter == 2.  (base == 40 alone can't catch that: its
// assignment is idempotent.)
var counter int
var _ int = bumpCounter()

func bumpCounter() int {
	counter = counter + 1
	return 0
}

#[c_export("ffi_counter")]
func GetCounter() int { return counter }

// A NARROW SIGNED param exported to C.  A C caller passes a negative int32 in w0 with
// bits[32:63] zeroed (an aarch64 w-write clears the high half), so a native callee that
// spills the whole x0 and, at -O1+, tests it with a 64-bit signed compare sees a large
// POSITIVE value unless it sign-extends the narrow reg param on entry.  Guards the
// #[c_export] register-param normalization (regression: ffi_sgn(-5) returned 0).
#[c_export("ffi_sgn")]
func Sgn(x int32) int {
	if x < cast(int32, 0) {
		return 1
	}
	return 0
}

// A narrow SIGNED param behind a `readonly` qualifier: the TYP_READONLY wrapper
// must be peeled for machine width/signedness (SubWordNarrow), else a C caller's
// negative int8 is zero-extended and read positive (ffi_ro(-3) -> 0 not 1).
#[c_export("ffi_ro")]
func FRo(x readonly int8) int {
	if x < cast(int8, 0) {
		return 1
	}
	return 0
}

// Narrow RETURNS: the callee must extend a sub-`int`-width result per the
// platform C ABI, because a clang caller at -O1+ trusts the callee (AssertS/Zext)
// and skips its own re-extension — so an un-extended i8/i16/i1 return surfaces as
// dirty upper bits / a wrong value.  Each derives its narrow result from a WIDER
// argument (cast truncation) so the natural codegen would leave nonzero upper
// bits without the signext/zeroext fix.  Read at -O2 by the narrow-returns driver.
#[c_export("ffi_reti8")]
func RetI8(x int) int8 { return cast(int8, x) }

#[c_export("ffi_reti16")]
func RetI16(x int) int16 { return cast(int16, x) }

#[c_export("ffi_retu8")]
func RetU8(x int) uint8 { return cast(uint8, x) }

#[c_export("ffi_retbool")]
func RetBool(x int) bool { return x != 0 }

// A narrow SIGNED param passed on the STACK: nine int32 params exceed the argument
// registers (six GP on SysV x64, eight on AAPCS64), so the ninth (a8) is stack-passed on
// both.  A C caller may store a full word into a8's 8-byte slot whose high bits are junk
// (the driver forces exactly that); a native callee that spilled the whole slot would, at
// -O1+ under a 64-bit signed compare, read that junk and see a large POSITIVE value.
// Returns 1 iff a8 is a negative int32 — the stack sibling of ffi_sgn's register check,
// guarding the #[c_export] STACK-arg normalization.  Only a8 is inspected.
#[c_export("ffi_stack_sgn")]
func StackSgn(a0 int32, a1 int32, a2 int32, a3 int32, a4 int32, a5 int32,
		a6 int32, a7 int32, a8 int32) int {
	if a8 < cast(int32, 0) {
		return 1
	}
	return 0
}

// A >16-byte struct passed BY VALUE.  Binate's internal convention hands a
// >16-byte aggregate over as a single pointer-in-register, but the platform C ABI
// passes it by value (SysV MEMORY / on the stack on x86-64; split across r0-r3 +
// stack on arm32).  Without an adapting entry thunk the mangled definition reads a
// pointer where a C caller placed value bytes — garbage / a crash.  aarch64's
// conventions coincide (a >16-byte aggregate rides a pointer both ways), so it
// stays a plain alias.  Returns a mix of the fields so a wrong read is visible.
type FfiBig struct {
	a int64
	b int64
	c int64
}

#[c_export("ffi_bigstruct")]
func BigStruct(x FfiBig) int64 { return x.a * cast(int64, 100) + x.b * cast(int64, 10) + x.c }

// A >16-byte aggregate (forces the entry thunk on x86-64 / arm32) FOLLOWED by an
// x86-64 SSE (float) aggregate.  On x86-64 the SSE aggregate rides XMM (SSE-split)
// under BOTH the C ABI and Binate's internal convention, so the thunk must declare
// AND forward it SSE-split — not the GP `[N x i64]` coercion, which read it from a
// GP register the C caller never used (a silent miscompile that still compiled).
// aarch64 stays a plain alias (a >16 aggregate rides a pointer both ways; the HFA
// rides v0/v1), so this also confirms the alias path for a float aggregate param.
type FfiVec2 struct { x float32; y float32 }

#[c_export("ffi_bigvec")]
func BigVec(big FfiBig, v FfiVec2) int64 {
	return big.a + big.b + big.c + cast(int64, cast(int, v.x)) + cast(int64, cast(int, v.y))
}

// A MIXED int+float aggregate in the "register-class in C / memory-class
// internally" straddle: the >16 `big` (internal pointer, +1 GP) plus five int64
// args fill the internal GP file, so `mix` {i64,f64} goes memory-class internally
// (a byval pointer); but `big` is SysV MEMORY in C (0 GP), so `mix` stays
// register-class in C, passed SSE-split (its i64 in a GP reg, its f64 in XMM).  The
// thunk must receive it SSE-split, reconstruct it, and forward a byval pointer —
// reading the GP form would return garbage for mix.f.  Uses both fields so either
// half being misread shows.
type FfiMix struct { i int64; f float64 }

#[c_export("ffi_bigmix")]
func BigMix(big FfiBig, a int64, b int64, c int64, d int64, e int64, mix FfiMix) int64 {
	return big.a + big.b + big.c + a + b + c + d + e + mix.i + cast(int64, cast(int, mix.f))
}

// MULTI-VALUE returns crossing the C boundary.  A conforming C caller reads each
// tuple as the C struct it declares; the entry must present the platform C
// struct-return ABI, which diverges from Binate's internal multi-return
// convention in several ways (register-vs-sret budget, sub-word packing, HFA):
//   - Mret3i (24B, 3x i64): the internal convention register-returns it (fits the
//     GP return budget) but the C ABI sret's it (> 16B) — the entry must store the
//     register result into the caller's sret buffer.
//   - Mret2i (8B, 2x i32): both register-return, but the C ABI packs the two i32s
//     into ONE eightbyte where the internal convention spreads them — the entry
//     must present the coerced (packed) form.
//   - Mret4i (16B, 4x i32): on x86-64 the internal 3-GP-word budget sret's it while
//     the C ABI register-returns it in 2 eightbytes (coerce-from-sret); on aarch64
//     it is a sub-word packing coerce.
//   - Mret3f (24B, 3x f64): an aarch64 / arm32-hard-float HFA (returned in FP
//     registers both ways → plain alias); on x86-64 it is a > 16B sret.
// Read back by driver_multiret.c across whichever host arch runs the e2e.
#[c_export("mret3i")]
func Mret3i() (int64, int64, int64) {
	return cast(int64, 10), cast(int64, 20), cast(int64, 30)
}

#[c_export("mret2i")]
func Mret2i() (int32, int32) { return cast(int32, 7), cast(int32, 9) }

#[c_export("mret4i")]
func Mret4i() (int32, int32, int32, int32) {
	return cast(int32, 1), cast(int32, 2), cast(int32, 3), cast(int32, 4)
}

#[c_export("mret3f")]
func Mret3f() (float64, float64, float64) {
	return cast(float64, 1), cast(float64, 2), cast(float64, 3)
}

// MIXED int+float word-sized tuples: on aarch64 a non-HFA composite returns
// WHOLLY in GP registers, but the internal convention puts the float field in a D
// register — so even these all-8-byte tuples must be repacked.  (float64, @Error)
// is the value-or-error idiom; here (int64,float64) / (float64,int64) stand in.
#[c_export("mretif")]
func Mretif() (int64, float64) { return cast(int64, 5), cast(float64, 6) }

#[c_export("mretfi")]
func Mretfi() (float64, int64) { return cast(float64, 8), cast(int64, 9) }

// PADDED tuple: (int32,int64) has an interior pad between the sub-word i32 and the
// i64, so its per-field-coerced boundary return type differs STRUCTURALLY from the
// raw padded aggregate (the pad shifts the i64 into the next return register).  A
// thunk that forwards the raw padded type instead of the coerced boundary form
// reads the second field from the wrong register — the exact regression class.
#[c_export("mretpad")]
func Mretpad() (int32, int64) { return cast(int32, 11), cast(int64, 22) }

// __c_entry POINTERS to multi-return functions: each getter hands C the address
// of a callback that returns a divergent tuple, so C invokes it THROUGH the
// pointer.  This must present the same platform struct-return ABI the #[c_export]
// entries do — the pointer names the weak __centry.<mangled> return-adaptation
// thunk (or the mangled entry directly when the return needs no adaptation).
// Reuses the Mret* targets above; a getter returns *uint8 (C void*), a pure
// compile-time symbol address, so the facade stays self-contained.
#[c_export("get_cb_mret3i")]
func GetCbMret3i() *uint8 { return __c_entry(Mret3i) }

#[c_export("get_cb_mret2i")]
func GetCbMret2i() *uint8 { return __c_entry(Mret2i) }

#[c_export("get_cb_mret4i")]
func GetCbMret4i() *uint8 { return __c_entry(Mret4i) }

#[c_export("get_cb_mretif")]
func GetCbMretif() *uint8 { return __c_entry(Mretif) }

#[c_export("get_cb_mretpad")]
func GetCbMretpad() *uint8 { return __c_entry(Mretpad) }
EOF

# --- a C driver that calls the exports by their C names -------------------
cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern int ffi_add(int, int);
extern int ffi_mul(int, int);
extern int ffi_sub(int, int);
extern int ffi_sub2(int, int);
extern long ffi_sgn(int);
extern long ffi_ro(int);
/* Deliberately declared with WIDE (long) params so the C caller stores full 64-bit words
   into the stack-arg slots — the low 32 bits are the intended int32, the high bits are junk.
   This is the "C leaves the narrow stack slot's high bytes dirty" case; the callee reads
   int32.  0xFFFFFFFBL == 0x00000000FFFFFFFB: low 32 = -5 (int32), high 32 = 0, so a buggy
   full-8-byte reload reads a large POSITIVE value.  ffi_stack_sgn returns 1 iff its 9th
   (stack-passed) arg is a negative int32. */
extern long ffi_stack_sgn(long, long, long, long, long, long, long, long, long);
int main(void) {
    printf("%d %d %d %d %ld %ld %ld %ld %ld %ld\n",
           ffi_add(20, 22), ffi_mul(6, 7),
           ffi_sub(50, 8), ffi_sub2(100, 1),
           ffi_sgn(-5), ffi_sgn(5),
           ffi_ro(-3), ffi_ro(3),
           ffi_stack_sgn(0, 0, 0, 0, 0, 0, 0, 0, 0xFFFFFFFBL),
           ffi_stack_sgn(0, 0, 0, 0, 0, 0, 0, 0, 5L));
    return 0;
}
EOF

# --- a C driver that reads NARROW-width returns at -O2 --------------------
# Compiled at -O2 so clang trusts the callee's ABI extension (AssertS/Zext) and
# omits its own re-extension of each sub-`int` result — at -O0 clang re-extends
# on the caller side and would MASK an un-extended callee return.  Each result is
# widened to int and printed, so a callee that failed to sign/zero-extend shows
# dirty upper bits as a wrong value.
cat > "$TMP/driver_narrow.c" <<'EOF'
#include <stdio.h>
extern signed char ffi_reti8(int);
extern short ffi_reti16(int);
extern unsigned char ffi_retu8(int);
extern _Bool ffi_retbool(int);
int main(void) {
    int a = ffi_reti8(507);       /* trunc -> 0xFB   = -5   (signed)   */
    int b = ffi_reti16(0x1FF80);  /* trunc -> 0xFF80 = -128 (signed)   */
    int c = ffi_retu8(456);       /* trunc -> 0xC8   = 200  (unsigned) */
    int d = ffi_retbool(507);     /* nonzero -> true = 1               */
    printf("%d %d %d %d\n", a, b, c, d);
    return 0;
}
EOF
WANT_NARROW="-5 -128 200 1"

# check_narrow_returns <label> <extra-bnc-flags> <required>
#   Like check_backend, but links the -O2 narrow-returns driver and checks the
#   sub-`int` return extension.  Same required/skip semantics.
check_narrow_returns() {
    label="narrow-$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ffiexp >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ffiexp.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ffiexp) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w -O2 "$TMP/driver_narrow.c" "$work/ffiexp.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of -O2 narrow-returns driver + facade object failed" \
             "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT_NARROW" ]; then
        pass "$label: -O2 C caller reads sign/zero-extended narrow #[c_export] returns: '$got'"
    else
        fail "$label: narrow-return output mismatch (got '$got', want '$WANT_NARROW')"
    fi
}

# --- a C driver that passes a >16-byte struct BY VALUE --------------------
# A conforming C caller passes the 24-byte struct per the platform ABI (SysV
# MEMORY / on the stack on x86-64).  Without the #[c_export] entry thunk the
# mangled definition reads a pointer where the bytes are — garbage or a crash.
cat > "$TMP/driver_bigagg.c" <<'EOF'
#include <stdio.h>
struct FfiBig { long a, b, c; };
struct FfiVec2 { float x, y; };
struct FfiMix { long i; double f; };
extern long ffi_bigstruct(struct FfiBig);
extern long ffi_bigvec(struct FfiBig, struct FfiVec2);
extern long ffi_bigmix(struct FfiBig, long, long, long, long, long, struct FfiMix);
int main(void) {
    struct FfiBig x = {1, 2, 3};
    printf("%ld\n", ffi_bigstruct(x));   /* expect 1*100 + 2*10 + 3 = 123 */
    /* A >16 struct (forces the thunk) FOLLOWED by a float aggregate: on x86-64
       the vec rides XMM, so the thunk must handle it SSE-split. 10+20+30+4+5. */
    struct FfiBig b = {10, 20, 30};
    struct FfiVec2 v = {4.0f, 5.0f};
    printf("%ld\n", ffi_bigvec(b, v));   /* expect 60 + 4 + 5 = 69 */
    /* A MIXED {i64,f64} aggregate in the register-class-in-C / memory-internally
       straddle (>16 big + 5 int64s fill the internal GP file): the thunk must
       receive `mix` SSE-split (i64 in GP, f64 in XMM) and reconstruct it. */
    struct FfiBig b2 = {1, 2, 3};
    struct FfiMix m = {6, 7.0};
    printf("%ld\n", ffi_bigmix(b2, 2, 3, 4, 5, 6, m));  /* 6 + 20 + 6 + 7 = 39 */
    return 0;
}
EOF
WANT_BIGAGG="123
69
39"

# check_bigagg <label> <extra-bnc-flags> <required>
#   Links the >16-byte by-value-struct driver and checks the callee read the
#   fields correctly.  Same required/skip semantics as check_narrow_returns.
check_bigagg() {
    label="bigagg-$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ffiexp >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ffiexp.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ffiexp) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w "$TMP/driver_bigagg.c" "$work/ffiexp.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of big-struct driver + facade object failed" \
             "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT_BIGAGG" ]; then
        pass "$label: C passes a >16-byte struct by value; callee reads its fields: '$got'"
    else
        fail "$label: big-struct-by-value output mismatch (got '$got', want '$WANT_BIGAGG')"
    fi
}

# --- a C driver that reads MULTI-VALUE returns by struct ------------------
# Each #[c_export] tuple is declared as the C struct a conforming caller uses;
# the entry must adapt the internal multi-return convention to the platform C
# struct-return ABI (sret / eightbyte-packing / HFA — see the facade comments).
cat > "$TMP/driver_multiret.c" <<'EOF'
#include <stdio.h>
struct M3i { long a, b, c; };
struct M2i { int a, b; };
struct M4i { int a, b, c, d; };
struct M3f { double a, b, c; };
struct Mif { long a; double b; };
struct Mfi { double a; long b; };
struct Mpad { int a; long b; };
extern struct M3i mret3i(void);
extern struct M2i mret2i(void);
extern struct M4i mret4i(void);
extern struct M3f mret3f(void);
extern struct Mif mretif(void);
extern struct Mfi mretfi(void);
extern struct Mpad mretpad(void);
int main(void) {
    struct M3i a = mret3i(); printf("%ld %ld %ld\n", a.a, a.b, a.c);
    struct M2i b = mret2i(); printf("%d %d\n", b.a, b.b);
    struct M4i c = mret4i(); printf("%d %d %d %d\n", c.a, c.b, c.c, c.d);
    struct M3f d = mret3f(); printf("%.0f %.0f %.0f\n", d.a, d.b, d.c);
    struct Mif e = mretif(); printf("%ld %.0f\n", e.a, e.b);
    struct Mfi f = mretfi(); printf("%.0f %ld\n", f.a, f.b);
    struct Mpad g = mretpad(); printf("%d %ld\n", g.a, g.b);
    return 0;
}
EOF
WANT_MULTIRET="10 20 30
7 9
1 2 3 4
1 2 3
5 6
8 9
11 22"

# --- a C driver that invokes multi-return callbacks THROUGH __c_entry pointers ---
# Each get_cb_* returns a void* naming the callback's C entry; C casts it to the
# right struct-returning function-pointer type and calls it.  The entry must adapt
# the internal multi-return convention to the platform struct-return ABI just as a
# direct #[c_export] call does — but reached through the __c_entry pointer (the weak
# __centry.<mangled> thunk), the case #[c_export]-only wiring used to miss.
cat > "$TMP/driver_centry.c" <<'EOF'
#include <stdio.h>
struct M3i { long a, b, c; };
struct M2i { int a, b; };
struct M4i { int a, b, c, d; };
struct Mif { long a; double b; };
struct Mpad { int a; long b; };
typedef struct M3i (*cb_m3i)(void);
typedef struct M2i (*cb_m2i)(void);
typedef struct M4i (*cb_m4i)(void);
typedef struct Mif (*cb_mif)(void);
typedef struct Mpad (*cb_mpad)(void);
extern void *get_cb_mret3i(void);
extern void *get_cb_mret2i(void);
extern void *get_cb_mret4i(void);
extern void *get_cb_mretif(void);
extern void *get_cb_mretpad(void);
int main(void) {
    struct M3i a = ((cb_m3i)get_cb_mret3i())(); printf("%ld %ld %ld\n", a.a, a.b, a.c);
    struct M2i b = ((cb_m2i)get_cb_mret2i())(); printf("%d %d\n", b.a, b.b);
    struct M4i c = ((cb_m4i)get_cb_mret4i())(); printf("%d %d %d %d\n", c.a, c.b, c.c, c.d);
    struct Mif d = ((cb_mif)get_cb_mretif())(); printf("%ld %.0f\n", d.a, d.b);
    struct Mpad e = ((cb_mpad)get_cb_mretpad())(); printf("%d %ld\n", e.a, e.b);
    return 0;
}
EOF
WANT_CENTRY="10 20 30
7 9
1 2 3 4
5 6
11 22"

# check_multiret <label> <extra-bnc-flags> <required>
#   Links the multi-value-return driver and checks the C caller reads each tuple
#   correctly.  Same required/skip semantics as check_bigagg.
check_multiret() {
    label="multiret-$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ffiexp >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ffiexp.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ffiexp) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w "$TMP/driver_multiret.c" "$work/ffiexp.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of multi-return driver + facade object failed" \
             "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT_MULTIRET" ]; then
        pass "$label: C reads #[c_export] multi-value returns by struct: '$(echo "$got" | tr '\n' '/')'"
    else
        fail "$label: multi-return output mismatch (got '$got', want '$WANT_MULTIRET')"
    fi
}

# check_centry <label> <extra-bnc-flags> <required>
#   Links the __c_entry-pointer driver and checks C reads each tuple correctly when
#   the multi-return callback is invoked THROUGH the __c_entry pointer (the entry is
#   the weak __centry.<mangled> return-adaptation thunk).  Same required/skip
#   semantics as check_multiret.
check_centry() {
    label="centry-$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ffiexp >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ffiexp.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ffiexp) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w "$TMP/driver_centry.c" "$work/ffiexp.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of __c_entry driver + facade object failed" \
             "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT_CENTRY" ]; then
        pass "$label: C invokes multi-return callbacks via __c_entry: '$(echo "$got" | tr '\n' '/')'"
    else
        fail "$label: __c_entry callback output mismatch (got '$got', want '$WANT_CENTRY')"
    fi
}

# check_backend <label> <extra-bnc-flags> <required>
#   Compile the facade with the given backend flags, link the C driver against
#   the object, run, and check output.  `required=1` -> a compile failure is a
#   hard FAIL; `required=0` (the native variant) -> a compile that produces no
#   object SKIPs (the host's native backend may not cover this facade yet), but a
#   produced-but-broken object still FAILs at link/run.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            $extra --build-dir "$work" --pkg ffiexp >"$work/pkg.log" 2>&1 \
            || [ ! -f "$work/ffiexp.o" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile of facade (--pkg ffiexp) produced no object" \
                 "$(tail -5 "$work/pkg.log")"
        else
            skip "$label: native --pkg unavailable for this host (no object emitted)"
        fi
        return
    fi
    if ! "$CLANG" -w "$TMP/driver.c" "$work/ffiexp.o" -o "$work/run" 2>"$work/link.err" \
            || [ ! -x "$work/run" ]; then
        fail "$label: link of C driver + facade object failed" "$(head -6 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "$WANT" ]; then
        pass "$label: C calls #[c_export] Binate functions (public, private, multi-name): '$got'"
    else
        fail "$label: c_export call output mismatch (got '$got', want '$WANT')"
    fi
}

# check_library builds the facade + its transitive closure into a static
# archive via `bnc --library` (the Phase-5a "a Binate .a a C program inits and
# calls into" contract), then links it into a C driver that inits it via the
# well-known `bn_init` symbol, calls the exports, and proves bn_init ran the
# package initializers exactly ONCE (ffi_base == 40 shows the inits ran;
# ffi_counter == 1 across two bn_init() calls shows the run-once guard held).  The
# archive is self-contained except libc and supplies no `main` of its own, so
# there is no `main` collision with the driver's own.
check_library() {
    work="$TMP/library"
    mkdir -p "$work"
    if ! "$GEN1" -I "$TMP/if:$IFACE" -L "$TMP/im:$IMPL" \
            --build-dir "$work" -o "$work/libffiexp.a" --library ffiexp >"$work/lib.log" 2>&1 \
            || [ ! -f "$work/libffiexp.a" ]; then
        fail "library: --library ffiexp produced no archive" "$(tail -5 "$work/lib.log")"
        return
    fi
    # Link the archive into a C driver that inits it (bn_init) and calls the
    # exports.  The archive is self-contained except libc and defines no `main`,
    # so the driver supplies the single `main`.
    cat > "$work/driver.c" <<'EOF'
#include <stdio.h>
extern void bn_init(void);
extern int ffi_add(int, int);
extern int ffi_mul(int, int);
extern int ffi_sub(int, int);
extern int ffi_sub2(int, int);
extern int ffi_base(void);
extern int ffi_counter(void);
int main(void) {
    bn_init();  /* run every package's __init once, in dependency order */
    bn_init();  /* idempotent: the run-once guard must NOT re-run inits */
    printf("%d %d %d %d %d %d\n",
           ffi_add(20, 22), ffi_mul(6, 7), ffi_sub(50, 8), ffi_sub2(100, 1),
           ffi_base(), ffi_counter());
    return 0;
}
EOF
    if ! "$CLANG" -w "$work/driver.c" "$work/libffiexp.a" -o "$work/run" \
            2>"$work/link.err" || [ ! -x "$work/run" ]; then
        fail "library: link of C driver + --library archive failed" \
             "$(head -8 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    want="$WANT_BASE 40 1"  # library driver: + ffi_base ffi_counter (no ffi_sgn call)
    if [ "$got" = "$want" ]; then
        pass "library: bn_init + #[c_export] calls from a C driver (base=40 -> inits ran; counter=1 -> run-once): '$got'"
    else
        fail "library: bn_init/export output mismatch (got '$got', want '$want')"
    fi
}

# check_library_alloc — a --library archive whose closure ALLOCATES must stay
# self-contained.  On aarch64 the portable Binate rt.MemZero is #[build]-gated
# off in favour of a hand-asm .s, so `bnc --library` must archive that .s object
# alongside the closure; otherwise the rt member references MemZero (via
# rt.Alloc) but nothing defines it, and a caller's link fails undefined.  The
# shared ffiexp facade above is deliberately allocation-free, so this uses its
# own tiny allocating facade.
check_library_alloc() {
    work="$TMP/library_alloc"
    mkdir -p "$work" "$TMP/if2" "$TMP/im2/allocx"
    cat > "$TMP/if2/allocx.bni" <<'EOF'
package "allocx"

func Sum(n int) int
EOF
    cat > "$TMP/im2/allocx/lib.bn" <<'EOF'
package "allocx"

// Allocates managed memory (make_slice -> rt.Alloc -> rt.MemZero), so the
// archived closure references MemZero and the archive must define it.
#[c_export("allocx_sum")]
func Sum(n int) int {
	var s @[]int = make_slice(int, n)
	for i := 0; i < n; i++ { s[i] = i }
	var total int = 0
	for i := 0; i < n; i++ { total = total + s[i] }
	return total
}
EOF
    if ! "$GEN1" -I "$TMP/if2:$IFACE" -L "$TMP/im2:$IMPL" \
            --build-dir "$work" -o "$work/liballocx.a" --library allocx >"$work/lib.log" 2>&1 \
            || [ ! -f "$work/liballocx.a" ]; then
        fail "library-alloc: --library allocx produced no archive" "$(tail -5 "$work/lib.log")"
        return
    fi
    cat > "$work/driver.c" <<'EOF'
#include <stdio.h>
extern void bn_init(void);
extern int allocx_sum(int);
int main(void) {
    bn_init();
    printf("%d\n", allocx_sum(5));  /* 0+1+2+3+4 = 10 */
    return 0;
}
EOF
    if ! "$CLANG" -w "$work/driver.c" "$work/liballocx.a" -o "$work/run" \
            2>"$work/link.err" || [ ! -x "$work/run" ]; then
        fail "library-alloc: link of C driver + allocating --library archive failed" \
             "$(head -8 "$work/link.err")"
        return
    fi
    got="$("$work/run" 2>&1)"
    if [ "$got" = "10" ]; then
        pass "library-alloc: allocating closure archived self-contained (rt.MemZero resolved): '$got'"
    else
        fail "library-alloc: output mismatch (got '$got', want '10')"
    fi
}

# LLVM backend (default) — always required.
check_backend "llvm" "" 1
# Native backend — real link+run coverage of the second-symbol emission when the
# host's native backend can emit the facade; self-skips otherwise.
check_backend "native" "--backend native" 0
# Native at -O2 — exercises the #[c_export] narrow register-param sign-extension: at -O1+
# mem2reg promotes the param, so ffi_sgn(-5) must still be 1 (a plain 64-bit reload of an
# un-extended negative int32 reads positive).  Self-skips if the host native backend cannot
# emit the facade.
check_backend "native-O2" "--backend native -O2" 0
# Narrow sub-`int` returns read by an -O2 clang caller — the LLVM callee must
# carry signext/zeroext on the c_export define (a plain -O2 caller trusts it and
# skips re-extension).  LLVM is required; native self-skips when the host backend
# can't emit the facade (native returns over-satisfy, so it must pass when it runs).
check_narrow_returns "llvm" "" 1
check_narrow_returns "native" "--backend native" 0

# >16-byte struct passed BY VALUE — both backends adapt.  LLVM: an entry thunk on
# x86-64 / arm32, a plain alias on aarch64 (conventions coincide).  Native: an
# adapter trampoline on x86-64, a plain entry on aarch64.  On an aarch64 host these
# exercise the alias/direct path; on an x86-64 host, the thunk / trampoline.  (The
# native check self-skips where the host native backend can't emit the facade.)
check_bigagg "llvm" "" 1
check_bigagg "native" "--backend native" 0

# MULTI-VALUE returns read by struct — both backends adapt the tuple to the C
# struct-return ABI (sret / eightbyte-packing / HFA, per the host arch).  LLVM is
# required; native self-skips when the host backend can't emit the facade.
check_multiret "llvm" "" 1
check_multiret "native" "--backend native" 0

# MULTI-VALUE returns reached THROUGH a __c_entry callback pointer — the entry the
# pointer names must adapt the tuple to the C struct-return ABI too (the weak
# __centry.<mangled> thunk), the case #[c_export]-only return wiring used to miss.
check_centry "llvm" "" 1
check_centry "native" "--backend native" 0

# The --library archive: init-once-via-bn_init + call the exports from a real .a.
check_library
# An allocating --library closure must archive self-contained (rt.MemZero).
check_library_alloc

summary
