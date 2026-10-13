#!/bin/sh
# e2e/arm32-ffi-export.sh — arm32 #[c_export] end-to-end.  A C program compiled in
# THUMB mode (the armhf default) calls Binate #[c_export] functions built by the
# NATIVE arm32 backend (and again by the LLVM backend), run under qemu-arm.
# Exercises arm32 C-boundary mechanisms that nothing else covers:
#
#   1. >16-byte by-value aggregates at the C boundary — AAPCS32 splits such an
#      aggregate across r0-r3 + the stack, and so does Binate, so the export name is
#      the mangled entry itself; a narrow scalar after the aggregate still gets the
#      re-extending entry; once a float has overflowed the VFP bank to the stack, an
#      aggregate that does not fit the remaining core registers goes wholly to the
#      stack (AAPCS32 C.5) rather than splitting; and
#   2. ARM/Thumb INTERWORKING — the native functions are A32 (ARM) code, so a
#      Thumb caller's BL must be routed through an interworking veneer, which bfd
#      sets up only from the callee's STT_FUNC type (+ the .text "$a" mapping
#      symbol).  A regression in either shows up here as wrong output or a SIGILL.
#
#   3. hard-float multi-value RETURNS whose C struct is a homogeneous float aggregate
#      but which carry a struct field — C reads every member from s0.. / d0.., while
#      Binate returns the struct field in core registers (or, past four words, through
#      a hidden buffer), so the entry repacks the members into VFP registers; plus a
#      tuple C returns through a hidden buffer with a struct field at offset 4, and
#      one C returns packed in r0 with an array field at offset 1.
#
# Neither is covered elsewhere: conformance is pure Binate (ARM->ARM, no Thumb
# caller), and e2e/ffi-export.sh's native check runs on the HOST arch, never
# native arm32.  The facade is built by BOTH the native and the LLVM backends (the
# third mechanism is shared C-boundary classification the two must agree on).
#
# The C driver MUST be built with gcc/bfd (NOT clang/lld): bfd relies on STT_FUNC
# to interwork a Thumb caller into an ARM function, so a regressed symbol type
# reappears here as a crash; clang/lld tolerates the missing type and would not
# catch it.
#
# Auto-discovered by .github/workflows/e2e-tests.yml — the `arm32` name prefix
# gates in the qemu-user-static + gcc-arm-linux-gnueabihf install on the Linux
# runner.  SKIPs (exit 0) unless qemu-arm + a working arm-linux-gnueabihf gcc
# cross-toolchain is present; skips on macOS via arm32-ffi-export.skip.darwin
# (qemu-user emulates the Linux syscall ABI and cannot run on macOS).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
[ -d "$BINATE_DIR/pkg" ] || { echo "FAIL: not a binate repo: $BINATE_DIR" >&2; exit 1; }

QEMU_ARM="${QEMU_ARM:-}"
[ -n "$QEMU_ARM" ] || QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
CC="${ARM32_CC:-$(command -v arm-linux-gnueabihf-gcc || true)}"

# --- cheap prereq SKIPs (before any temp/build work) ----------------------
[ -n "$QEMU_ARM" ] || { echo "SKIP: qemu-arm(-static) not found (needed to run the arm32 binary)"; exit 0; }
[ -n "$CC" ] || { echo "SKIP: arm-linux-gnueabihf-gcc not found (needed to compile the Thumb C driver)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_a32ffi.XXXXXX")" || true
[ -d "$TMP" ] || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The binary is linked -static, so it is self-contained (no loader / QEMU_LD_PREFIX
# needed) AND non-PIE: the native backend emits absolute relocations (movw/movt),
# which a PIE/shared-object link rejects.  -march is left at the arm-linux-gnueabihf
# default (armv7-a + VFP, hard-float) — passing -march=armv7-a would drop the FPU
# and clash with the toolchain's hard-float default.

# --- runtime prereq probe: cross-compile (Thumb) AND run a tiny arm binary ----
# Gates on the FULL dependency (gcc can build a static Thumb arm-linux-gnueabihf
# binary + qemu can run it), not just "gcc exists" — a compile-only check would red
# a partial-toolchain runner at the real run instead of skipping.
if ! { echo 'int main(void){return 0;}' \
        | "$CC" -mthumb -static -x c - -o "$TMP/probe" 2>/dev/null \
        && "$QEMU_ARM" "$TMP/probe" >/dev/null 2>&1; }; then
    echo "SKIP: cannot cross-compile + run a static arm-linux-gnueabihf binary under qemu" \
         "(need gcc-arm-linux-gnueabihf + its arm32 glibc)"
    exit 0
fi

# --- build a host bnc (the arm32 cross-compiler) --------------------------
echo "Building host bnc (cross-compiler)..."
BNC="$TMP/bnc"
build_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" 2>&1)" || true
[ -x "$BNC" ] || { echo "FAIL: host bnc build failed" >&2; echo "$build_log" | tail -5 >&2; exit 1; }

A32_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-linux)"
A32_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl  --base "$BINATE_DIR" --target arm32-linux)"

# --- the #[c_export] facade: a >16-byte by-value struct param in several shapes -
mkdir -p "$TMP/if" "$TMP/im/a32ffi"
cat > "$TMP/if/a32ffi.bni" <<'BNI'
package "a32ffi"
BNI
cat > "$TMP/im/a32ffi/lib.bn" <<'BN'
package "a32ffi"

type Big struct { a int64
	b int64
	c int64 }

// A lone >16-byte by-value aggregate (24B): AAPCS32 splits it across r0-r3 +
// the stack, for C and Binate alike.
#[c_export("a32_big")]
func takeBig(x Big) int64 { return x.a + x.b + x.c }

// A big aggregate followed by a trailing scalar — the scalar follows the
// aggregate's stack words.
#[c_export("a32_bigsmall")]
func takeBigSmall(x Big, y int32) int64 { return x.a + x.b + x.c + cast(int64, y) }

// A narrow (signed int8) scalar after a big aggregate — the callee must see it
// sign-extended even though a C caller may leave the high bits unspecified.
#[c_export("a32_narrowafter")]
func takeNarrowAfter(x Big, y int8) int64 { return x.a + x.b + x.c + cast(int64, y) }

// A big aggregate PARAM and a big aggregate (sret) RETURN together.
#[c_export("a32_sretbig")]
func takeSretBig(x Big) Big {
	var r Big
	r.a = x.a * 2
	r.b = x.b * 2
	r.c = x.c * 2
	return r
}

// Nine float64 overflow the VFP bank, so the ninth is on the stack before the int32
// (r0) and the struct: an aggregate may split across core registers and the stack
// only while nothing is on the stack yet (AAPCS32 C.5), so the 24-byte struct, which
// does not fit r1-r3, goes wholly to the stack and the trailing int32 follows it.
#[c_export("a32_vfpover")]
func takeVfpOver(d0 float64, d1 float64, d2 float64, d3 float64, d4 float64, d5 float64,
		d6 float64, d7 float64, d8 float64, k int32, x Big, z int32) int64 {
	return cast(int64, cast(int32, d8)) + cast(int64, k) * 10 + x.a + x.b + x.c + cast(int64, z) * 1000
}

type Mid struct { a int64
	b int64 }

// The same with a 16-byte struct, which would otherwise split across r2-r3 + stack.
#[c_export("a32_vfpovermid")]
func takeVfpOverMid(d0 float64, d1 float64, d2 float64, d3 float64, d4 float64, d5 float64,
		d6 float64, d7 float64, d8 float64, k int32, m Mid) int64 {
	return cast(int64, cast(int32, d8)) + cast(int64, k) * 10 + m.a + m.b
}

type V2f struct { x float32
	y float32 }

type D2 struct { x float64
	y float64 }

type D3 struct { x float64
	y float64
	z float64 }

type Pair struct { a int32
	b int32 }

// Hard-float FP-HFA multi-value returns with a struct field: C reads s0..s2 / d0..d2
// (d0..d3); Binate returns the struct field in core registers — and (D3, float64)'s
// six words exceed the four core return registers, so its body returns through a
// buffer the entry supplies.
#[c_export("a32_mvf")]
func retVf() (V2f, float32) { return V2f{x: 1.5, y: 2.5}, cast(float32, 3.5) }

#[c_export("a32_mfv")]
func retFv() (float32, V2f) { return cast(float32, 4.5), V2f{x: 5.5, y: 6.5} }

#[c_export("a32_md2")]
func retD2() (D2, float64) { return D2{x: 7.5, y: 8.5}, cast(float64, 9.5) }

#[c_export("a32_md3")]
func retD3() (D3, float64) { return D3{x: 10.5, y: 11.5, z: 12.5}, cast(float64, 13.5) }

// (D3, float64) with arguments: Binate's hidden buffer pointer takes r0, so each
// core-register argument sits one register further on than C put it (d spills to
// the stack, the int64 is realigned), while the float64 stays in d0.
#[c_export("a32_md3a")]
func retD3a(a int32, b int32, c int32, d int32, e int64, f float64) (D3, float64) {
	return D3{x: cast(float64, a) + f, y: cast(float64, b * 10 + c), z: cast(float64, d)},
			cast(float64, e)
}

// A 4-byte tuple C returns packed in r0, with its array field at offset 1.
#[c_export("a32_mba")]
func retBa() (int8, [3]int8) { return cast(int8, 5), [3]int8{6, 7, 8} }

// A tuple C returns through a hidden buffer (12 bytes > 4) with its struct field at
// offset 4.
#[c_export("a32_mip")]
func retIp() (int32, Pair) { return cast(int32, 7), Pair{a: 8, b: 9} }

// The (D3, float64) entry reached through a __c_entry pointer.
#[c_export("a32_get_md3")]
func getMd3() *uint8 { return __c_entry(retD3) }

// A plain scalar export — the pure interworking control: a Thumb caller reaching
// an ARM function needs STT_FUNC even with no aggregate param.
#[c_export("a32_add")]
func add(a int32, b int32) int32 { return a + b }
BN

# --- a Thumb C driver that passes the structs BY VALUE --------------------
cat > "$TMP/driver.c" <<'C'
#include <stdio.h>
struct Big { long long a, b, c; };
extern long long a32_big(struct Big);
extern long long a32_bigsmall(struct Big, int);
extern long long a32_narrowafter(struct Big, signed char);
extern struct Big a32_sretbig(struct Big);
extern int a32_add(int, int);
struct Mid { long long a, b; };
extern long long a32_vfpover(double, double, double, double, double, double, double, double,
                             double, int, struct Big, int);
extern long long a32_vfpovermid(double, double, double, double, double, double, double, double,
                                double, int, struct Mid);
struct V2f { float x, y; };
struct D2 { double x, y; };
struct D3 { double x, y, z; };
struct Pair { int a, b; };
struct Mvf { struct V2f v; float z; };
struct Mfv { float z; struct V2f v; };
struct Md2 { struct D2 v; double z; };
struct Md3 { struct D3 v; double z; };
struct Mip { int a; struct Pair p; };
extern struct Mvf a32_mvf(void);
extern struct Mfv a32_mfv(void);
extern struct Md2 a32_md2(void);
extern struct Md3 a32_md3(void);
extern struct Mip a32_mip(void);
extern struct Md3 a32_md3a(int, int, int, int, long long, double);
struct Mba { signed char a; signed char b[3]; };
extern struct Mba a32_mba(void);
extern void *a32_get_md3(void);
typedef struct Md3 (*md3_fn)(void);

static int fails = 0;
static void chk(const char *n, long long got, long long want) {
    if (got == want) { printf("  %s: PASS (%lld)\n", n, got); }
    else { printf("  %s: FAIL got=%lld want=%lld\n", n, got, want); fails++; }
}
/* Each value is an exact binary fraction, so == is exact. */
static void chk4(const char *n, double a, double b, double c, double d,
                 double wa, double wb, double wc, double wd) {
    if (a == wa && b == wb && c == wc && d == wd) {
        printf("  %s: PASS (%.1f,%.1f,%.1f,%.1f)\n", n, a, b, c, d);
    } else {
        printf("  %s: FAIL got=(%g,%g,%g,%g) want=(%g,%g,%g,%g)\n", n, a, b, c, d, wa, wb, wc, wd);
        fails++;
    }
}
int main(void) {
    struct Big b = {100, 200, 300};
    chk("a32_add",         a32_add(40, 2),          42);   /* interworking control */
    chk("a32_big",         a32_big(b),              600);
    chk("a32_bigsmall",    a32_bigsmall(b, 7),      607);
    chk("a32_narrowafter", a32_narrowafter(b, -5),  595);
    struct Big r = a32_sretbig(b);
    if (r.a == 200 && r.b == 400 && r.c == 600) { printf("  a32_sretbig: PASS (%lld,%lld,%lld)\n", r.a, r.b, r.c); }
    else { printf("  a32_sretbig: FAIL got=(%lld,%lld,%lld) want=(200,400,600)\n", r.a, r.b, r.c); fails++; }
    chk("a32_vfpover",     a32_vfpover(1, 2, 3, 4, 5, 6, 7, 8, 9, 2, b, 3), 3629);
    struct Mid m = {40, 50};
    chk("a32_vfpovermid",  a32_vfpovermid(1, 2, 3, 4, 5, 6, 7, 8, 9, 2, m), 119);
    struct Mvf vf = a32_mvf(); chk4("a32_mvf", vf.v.x, vf.v.y, vf.z, 0, 1.5, 2.5, 3.5, 0);
    struct Mfv fv = a32_mfv(); chk4("a32_mfv", fv.z, fv.v.x, fv.v.y, 0, 4.5, 5.5, 6.5, 0);
    struct Md2 d2 = a32_md2(); chk4("a32_md2", d2.v.x, d2.v.y, d2.z, 0, 7.5, 8.5, 9.5, 0);
    struct Md3 d3 = a32_md3();
    chk4("a32_md3", d3.v.x, d3.v.y, d3.v.z, d3.z, 10.5, 11.5, 12.5, 13.5);
    struct Md3 d3p = ((md3_fn)a32_get_md3())();
    chk4("a32_get_md3", d3p.v.x, d3p.v.y, d3p.v.z, d3p.z, 10.5, 11.5, 12.5, 13.5);
    struct Md3 d3a = a32_md3a(1, 2, 3, 4, 5, 0.5);
    chk4("a32_md3a", d3a.v.x, d3a.v.y, d3a.v.z, d3a.z, 1.5, 23, 4, 5);
    struct Mba ba = a32_mba();
    chk("a32_mba", ba.a * 1000 + ba.b[0] * 100 + ba.b[1] * 10 + ba.b[2], 5678);
    struct Mip ip = a32_mip();
    chk("a32_mip", ip.a * 100 + ip.p.a * 10 + ip.p.b, 789);
    if (fails) { printf("%d FAILURE(S)\n", fails); return 1; }
    printf("ALL PASS\n"); return 0;
}
C

# run_backend <backend>: compile the facade with --backend <backend>, link the Thumb
# C driver against it, run under qemu-arm; returns non-zero on any failure.
run_backend() {
    be="$1"
    echo "Compiling facade (--backend $be --target arm32-linux)..."
    mkdir -p "$TMP/obj-$be"
    if ! "$BNC" -I "$TMP/if:$A32_I" -L "$TMP/im:$A32_L" \
            --backend "$be" --target arm32-linux --build-dir "$TMP/obj-$be" --pkg a32ffi \
            >"$TMP/pkg-$be.log" 2>&1 || [ ! -f "$TMP/obj-$be/a32ffi.o" ]; then
        echo "FAIL: $be arm32 facade compile (--pkg a32ffi) produced no object"
        tail -8 "$TMP/pkg-$be.log" | sed 's/^/    /'
        return 1
    fi
    echo "Linking Thumb C driver + $be arm32 facade, running under qemu-arm..."
    if ! "$CC" -mthumb -static -w "$TMP/driver.c" "$TMP/obj-$be/a32ffi.o" -o "$TMP/run-$be" \
            2>"$TMP/link-$be.err"; then
        echo "FAIL: link of Thumb C driver + $be arm32 facade failed"
        head -8 "$TMP/link-$be.err" | sed 's/^/    /'
        return 1
    fi
    out="$("$QEMU_ARM" "$TMP/run-$be" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | sed 's/^/    /'
    [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'ALL PASS'
}

status=0
for be in native llvm; do
    if run_backend "$be"; then
        echo "=== $be arm32 #[c_export] e2e: PASS ==="
    else
        echo "=== $be arm32 #[c_export] e2e: FAIL ==="
        status=1
    fi
done
exit $status
