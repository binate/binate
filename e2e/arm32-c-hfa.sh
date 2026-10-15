#!/bin/sh
# e2e/arm32-c-hfa.sh — homogeneous float aggregates (HFAs) across the arm32-linux
# hard-float C boundary, on both backends, under qemu-arm.
#
# AAPCS-VFP passes an HFA — a struct / array of 1-4 float32 or 1-4 float64 — as ONE
# co-processor register candidate: its members in consecutive s (float32) or d
# (float64) registers, back-filling holes like a float scalar; one that does not fit
# goes wholly to the stack and closes the VFP bank to every later float.  An HFA
# result comes back in s0..s3 / d0..d3 at any size.  A variadic call uses the base
# standard for every argument and the result: an HFA is then an ordinary composite
# in the core registers / on the stack, and a result over 4 bytes comes back
# through a hidden buffer.  This checks Binate against gcc-compiled C in both
# directions:
#
#   1. __c_call into C: HFA arguments that back-fill around float scalars, mix with
#      core-register arguments, and overflow the bank; HFA results of 4, 24 and 32
#      bytes; a variadic call with HFAs in its tail, with a FIXED HFA, and returning
#      an HFA (16 bytes, through the hidden buffer, and 4 bytes, in r0).
#   2. C into #[c_export]: HFA parameters (also past the bank) and results, and an
#      HFA function reached through a __c_entry pointer.
#
# The facade is compiled by BOTH backends (native and LLVM), each linked against
# the same C driver.  Each check combines the values with distinct weights, so a
# member in the wrong register shows up as a wrong number.
#
# Auto-discovered by .github/workflows/e2e-tests.yml — the `arm32` name prefix gates
# in qemu-user-static + gcc-arm-linux-gnueabihf on the Linux runner.  SKIPs unless
# that toolchain is present; skips on macOS via the .skip.darwin marker (qemu-user
# emulates the Linux syscall ABI and cannot run on macOS).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
[ -d "$BINATE_DIR/pkg" ] || { echo "FAIL: not a binate repo: $BINATE_DIR" >&2; exit 1; }

QEMU_ARM="${QEMU_ARM:-}"
[ -n "$QEMU_ARM" ] || QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
CC="${ARM32_CC:-$(command -v arm-linux-gnueabihf-gcc || true)}"

# --- cheap prereq SKIPs ---------------------------------------------------
[ -n "$QEMU_ARM" ] || { echo "SKIP: qemu-arm(-static) not found (needed to run the arm32 binary)"; exit 0; }
[ -n "$CC" ] || { echo "SKIP: arm-linux-gnueabihf-gcc not found (needed to compile the C peer)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_a32hfa.XXXXXX")" || true
[ -d "$TMP" ] || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# The binary is linked -static: self-contained (no loader / QEMU_LD_PREFIX) AND
# non-PIE (the native backend emits absolute movw/movt relocs a PIE link rejects).
# -march is left at the arm-linux-gnueabihf default (armv7-a + VFP, hard-float).

# --- runtime prereq probe: cross-compile + run a tiny arm binary ----------
if ! { echo 'int main(void){return 0;}' \
        | "$CC" -static -x c - -o "$TMP/probe" 2>/dev/null \
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

# --- the Binate facade ----------------------------------------------------
mkdir -p "$TMP/if" "$TMP/im/a32hfa"
cat > "$TMP/if/a32hfa.bni" <<'BNI'
package "a32hfa"
BNI
cat > "$TMP/im/a32hfa/lib.bn" <<'BN'
package "a32hfa"

type F1 struct { x float32 }

type F2 struct { x float32
	y float32 }

type F3 struct { x float32
	y float32
	z float32 }

type D2 struct { x float64
	y float64 }

type D3 struct { x float64
	y float64
	z float64 }

type D4 struct { a float64
	b float64
	c float64
	d float64 }

// --- __c_call into C ---

// a -> s0, d -> d1-d2 (s2-s5), b back-fills s1.
#[c_export("bn_backfill")]
func backfill(a float32, d D2, b float32) float64 { return __c_call("c_backfill", float64, a, d, b) }

// p -> s0-s1, i -> r0, q -> s2-s4.
#[c_export("bn_mix")]
func mix(p F2, i int32, q F3) float64 { return __c_call("c_mix", float64, p, i, q) }

// a -> d0-d3, b -> d4-d7; c and f no longer fit, so they go to the stack.
#[c_export("bn_over")]
func over(a D4, b D4, c D2, f float32) float64 { return __c_call("c_over", float64, a, b, c, f) }

#[c_export("bn_mkf1")]
func mkf1(x float32) float32 {
	var r F1 = __c_call("c_mkf1", F1, x)
	return r.x
}

#[c_export("bn_mkd3")]
func mkd3(x float64) float64 {
	var r D3 = __c_call("c_mkd3", D3, x)
	return r.x + r.y * 10.0 + r.z * 100.0
}

#[c_export("bn_mkd4")]
func mkd4(x float64) float64 {
	var r D4 = __c_call("c_mkd4", D4, x)
	return r.a + r.b * 10.0 + r.c * 100.0 + r.d * 1000.0
}

// A variadic call: every argument by the base standard.  n -> r0, p -> r1-r2, d -> the
// stack (8-aligned: r3 is skipped).
#[c_export("bn_vtail")]
func vtail(p F2, d D2) float64 { return __c_call("c_vtail", float64, cast(int32, 3), ..., p, d) }

// A FIXED HFA in a variadic call is a core-register composite too: d -> r0-r3.
#[c_export("bn_vfixed")]
func vfixed(d D2, n int32) float64 {
	return __c_call("c_vfixed", float64, d, n, ..., cast(float64, 0.25))
}

// A variadic call returning a 16-byte HFA: through the hidden buffer.
#[c_export("bn_vret")]
func vret(x float64) float64 {
	var r D2 = __c_call("c_vret", D2, cast(int32, 3), ..., x)
	return r.x + r.y * 10.0
}

// A variadic call returning a 4-byte HFA: in r0.
#[c_export("bn_vretf1")]
func vretf1(x float64) float32 {
	var r F1 = __c_call("c_vretf1", F1, cast(int32, 3), ..., x)
	return r.x
}

// --- C into #[c_export] ---

#[c_export("bn_scale")]
func scale(v D2, k float32) D2 { return D2{x: v.x * cast(float64, k), y: v.y * cast(float64, k)} }

#[c_export("bn_sumf3")]
func sumf3(a F3, b F1) float32 { return a.x + a.y * 10.0 + a.z * 100.0 + b.x * 1000.0 }

#[c_export("bn_overex")]
func overex(a D4, b D4, c D2, f float32) float64 {
	return a.a + a.d * 10.0 + b.a * 100.0 + b.d * 1000.0 + c.x * 10000.0 + c.y * 100000.0 +
			cast(float64, f) * 1000000.0
}

#[c_export("bn_mkd4ex")]
func mkd4ex(x float64) D4 { return D4{a: x, b: x + 1.0, c: x + 2.0, d: x + 3.0} }

#[c_export("bn_get_scale")]
func getScale() *uint8 { return __c_entry(scale) }
BN

# --- the C peer: callees for __c_call, and the driver --------------------
cat > "$TMP/driver.c" <<'C'
#include <stdio.h>
#include <stdarg.h>

struct F1 { float x; };
struct F2 { float x, y; };
struct F3 { float x, y, z; };
struct D2 { double x, y; };
struct D3 { double x, y, z; };
struct D4 { double a, b, c, d; };

double c_backfill(float a, struct D2 d, float b) { return a + d.x * 10 + d.y * 100 + b * 1000; }
double c_mix(struct F2 p, int i, struct F3 q) {
    return p.x + p.y * 10 + i * 100 + q.x * 1000 + q.y * 10000 + q.z * 100000;
}
double c_over(struct D4 a, struct D4 b, struct D2 c, float f) {
    return a.a + a.d * 10 + b.a * 100 + b.d * 1000 + c.x * 10000 + c.y * 100000 + f * 1000000;
}
struct F1 c_mkf1(float x) { struct F1 r = { x * 2 }; return r; }
struct D3 c_mkd3(double x) { struct D3 r = { x, x + 1, x + 2 }; return r; }
struct D4 c_mkd4(double x) { struct D4 r = { x, x + 1, x + 2, x + 3 }; return r; }
double c_vtail(int n, ...) {
    va_list ap; va_start(ap, n);
    struct F2 p = va_arg(ap, struct F2);
    struct D2 d = va_arg(ap, struct D2);
    va_end(ap);
    return p.x + p.y * 10 + d.x * 100 + d.y * 1000 + n * 10000;
}
double c_vfixed(struct D2 d, int n, ...) {
    va_list ap; va_start(ap, n);
    double z = va_arg(ap, double);
    va_end(ap);
    return d.x + d.y * 10 + n * 100 + z * 1000;
}
struct D2 c_vret(int n, ...) {
    va_list ap; va_start(ap, n);
    double x = va_arg(ap, double);
    va_end(ap);
    struct D2 r = { x, x * n + 1 };
    return r;
}
struct F1 c_vretf1(int n, ...) {
    va_list ap; va_start(ap, n);
    double x = va_arg(ap, double);
    va_end(ap);
    struct F1 r = { (float)(x * n) };
    return r;
}

extern double bn_backfill(float, struct D2, float);
extern double bn_mix(struct F2, int, struct F3);
extern double bn_over(struct D4, struct D4, struct D2, float);
extern float bn_mkf1(float);
extern double bn_mkd3(double);
extern double bn_mkd4(double);
extern double bn_vtail(struct F2, struct D2);
extern double bn_vfixed(struct D2, int);
extern double bn_vret(double);
extern float bn_vretf1(double);
extern struct D2 bn_scale(struct D2, float);
extern float bn_sumf3(struct F3, struct F1);
extern double bn_overex(struct D4, struct D4, struct D2, float);
extern struct D4 bn_mkd4ex(double);
extern void *bn_get_scale(void);
typedef struct D2 (*scale_fn)(struct D2, float);

static int fails = 0;
/* Every value is an exact binary fraction, so == is exact. */
static void chk(const char *n, double got, double want) {
    if (got == want) { printf("  %s: PASS (%g)\n", n, got); }
    else { printf("  %s: FAIL got=%.17g want=%.17g\n", n, got, want); fails++; }
}

int main(void) {
    struct F1 f1 = { 0.5f };
    struct F2 f2 = { 1.5f, 2.5f };
    struct F3 f3 = { 3.5f, 4.5f, 5.5f };
    struct D2 d2 = { 6.5, 7.5 };
    struct D4 d4a = { 1.5, 2.5, 3.5, 4.5 };
    struct D4 d4b = { 5.5, 6.5, 7.5, 8.5 };

    chk("backfill", bn_backfill(0.25f, d2, 0.75f), 0.25 + 65 + 750 + 750);
    chk("mix", bn_mix(f2, 3, f3), 1.5 + 25 + 300 + 3500 + 45000 + 550000);
    chk("over", bn_over(d4a, d4b, d2, 0.5f), 1.5 + 45 + 550 + 8500 + 65000 + 750000 + 500000);
    chk("mkf1", bn_mkf1(1.25f), 2.5);
    chk("mkd3", bn_mkd3(1.5), 1.5 + 25 + 350);
    chk("mkd4", bn_mkd4(1.5), 1.5 + 25 + 350 + 4500);
    chk("vtail", bn_vtail(f2, d2), 1.5 + 25 + 650 + 7500 + 30000);
    chk("vfixed", bn_vfixed(d2, 4), 6.5 + 75 + 400 + 250);
    chk("vret", bn_vret(1.5), 1.5 + 55);
    chk("vretf1", bn_vretf1(1.5), 4.5);

    struct D2 s = bn_scale(d2, 2.0f);
    chk("scale", s.x + s.y * 10, 13 + 150);
    chk("sumf3", bn_sumf3(f3, f1), 3.5 + 45 + 550 + 500);
    chk("overex", bn_overex(d4a, d4b, d2, 0.5f), 1.5 + 45 + 550 + 8500 + 65000 + 750000 + 500000);
    struct D4 m = bn_mkd4ex(1.5);
    chk("mkd4ex", m.a + m.b * 10 + m.c * 100 + m.d * 1000, 1.5 + 25 + 350 + 4500);
    struct D2 sp = ((scale_fn)bn_get_scale())(d2, 0.5f);
    chk("c_entry scale", sp.x + sp.y * 10, 3.25 + 37.5);

    if (fails) { printf("%d FAILURE(S)\n", fails); return 1; }
    printf("ALL PASS\n"); return 0;
}
C

# run_backend <backend>: compile the facade with --backend <backend>, link the C peer
# against it, run under qemu-arm; returns non-zero on any failure.
run_backend() {
    be="$1"
    echo "Compiling facade (--backend $be --target arm32-linux)..."
    mkdir -p "$TMP/obj-$be"
    if ! "$BNC" -I "$TMP/if:$A32_I" -L "$TMP/im:$A32_L" \
            --backend "$be" --target arm32-linux --build-dir "$TMP/obj-$be" --pkg a32hfa \
            >"$TMP/pkg-$be.log" 2>&1 || [ ! -f "$TMP/obj-$be/a32hfa.o" ]; then
        echo "FAIL: $be arm32 facade compile (--pkg a32hfa) produced no object"
        tail -8 "$TMP/pkg-$be.log" | sed 's/^/    /'
        return 1
    fi
    echo "Linking the C peer + $be arm32 facade, running under qemu-arm..."
    if ! "$CC" -static -w "$TMP/driver.c" "$TMP/obj-$be/a32hfa.o" -o "$TMP/run-$be" \
            2>"$TMP/link-$be.err"; then
        echo "FAIL: link of the C peer + $be arm32 facade failed"
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
        echo "=== $be arm32 HFA C-boundary e2e: PASS ==="
    else
        echo "=== $be arm32 HFA C-boundary e2e: FAIL ==="
        status=1
    fi
done
exit $status
