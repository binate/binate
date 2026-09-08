#!/bin/sh
# e2e/arm32-ccall-variadic-fixedfloat.sh — native arm32 hard-float variadic
# __c_call with a FIXED float/double param before `...`.
#
# Under AAPCS-VFP (arm32-linux hard-float) a variadic function is marshaled
# entirely by the BASE standard: EVERY argument — including the NAMED/fixed
# float/double params before `...` — rides the core GP registers / stack, NEVER
# the VFP (d) registers.  The rule is per-CALL: once the call is variadic, no
# float uses VFP.  A Binate native-arm32 __c_call that declares a fixed
# float/double before `...` must therefore place it in the GP file (a double in an
# even r-pair), matching a conforming C callee.  If it wrongly peels the fixed
# float to VFP, the fixed float AND every later arg mis-pass, and the C callee
# reads garbage.
#
# Flow: a C `main` calls a Binate #[c_export] wrapper (native arm32), which does a
# variadic __c_call into a C callee `vfn(double base, int n, ...)` compiled by
# gcc-arm-linux-gnueabihf (real AAPCS-VFP va_arg).  vfn encodes base+n+vararg so a
# mis-placed fixed double shows up as a wrong result under qemu-arm.
#
# Auto-discovered by .github/workflows/e2e-tests.yml — the `arm32` name prefix
# gates in qemu-user-static + gcc-arm-linux-gnueabihf on the Linux runner.  SKIPs
# unless that toolchain is present; skips on macOS via the .skip.darwin marker
# (qemu-user emulates the Linux syscall ABI, cannot run on macOS).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
[ -d "$BINATE_DIR/pkg" ] || { echo "FAIL: not a binate repo: $BINATE_DIR" >&2; exit 1; }

QEMU_ARM="${QEMU_ARM:-}"
[ -n "$QEMU_ARM" ] || QEMU_ARM="$(command -v qemu-arm-static || command -v qemu-arm || true)"
CC="${ARM32_CC:-$(command -v arm-linux-gnueabihf-gcc || true)}"

# --- cheap prereq SKIPs ---------------------------------------------------
[ -n "$QEMU_ARM" ] || { echo "SKIP: qemu-arm(-static) not found (needed to run the arm32 binary)"; exit 0; }
[ -n "$CC" ] || { echo "SKIP: arm-linux-gnueabihf-gcc not found (needed to compile the C callee/driver)"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_a32vff.XXXXXX")" || true
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

# --- the #[c_export] facade: variadic __c_call with fixed float/double params --
mkdir -p "$TMP/if" "$TMP/im/a32vff"
cat > "$TMP/if/a32vff.bni" <<'BNI'
package "a32vff"
BNI
cat > "$TMP/im/a32vff/lib.bn" <<'BN'
package "a32vff"

// A variadic __c_call whose FIXED args (before `...`) include a double.  Under
// AAPCS-VFP the fixed `base` must ride the GP pair r0:r1 (the call is variadic),
// not d0; `n` then r2, and the one variadic arg `x` r3.
#[c_export("bn_call1")]
func call1(base float64, n int32, x int32) int64 {
	return __c_call("vfn1", int64, base, n, ..., x)
}

// TWO fixed doubles before `...`: base0 -> r0:r1, base1 -> r2:r3, n spills to the
// stack, the variadic x follows.  Stresses that consecutive fixed doubles consume
// GP pairs (not VFP), so every later arg's slot is right.
#[c_export("bn_call2")]
func call2(base0 float64, base1 float64, n int32, x int32) int64 {
	return __c_call("vfn2", int64, base0, base1, n, ..., x)
}
BN

echo "Compiling facade (--backend native --target arm32-linux)..."
mkdir -p "$TMP/obj"
if ! "$BNC" -I "$TMP/if:$A32_I" -L "$TMP/im:$A32_L" \
        --backend native --target arm32-linux --build-dir "$TMP/obj" --pkg a32vff \
        >"$TMP/pkg.log" 2>&1 || [ ! -f "$TMP/obj/a32vff.o" ]; then
    echo "FAIL: native arm32 facade compile (--pkg a32vff) produced no object"
    tail -8 "$TMP/pkg.log" | sed 's/^/    /'
    exit 1
fi

# --- a C callee (real AAPCS-VFP va_arg) + driver --------------------------
cat > "$TMP/driver.c" <<'C'
#include <stdio.h>
#include <stdarg.h>

/* Fixed double `base` before `...`: a conforming AAPCS-VFP variadic callee reads
   it from the GP pair r0:r1, never d0.  Encodes base/n/x so a mis-placed fixed
   double yields a wrong result. */
long long vfn1(double base, int n, ...) {
    va_list ap; va_start(ap, n);
    int x = va_arg(ap, int);
    va_end(ap);
    return (long long)(base * 100.0) + n * 10 + x;
}

/* Two fixed doubles before `...`. */
long long vfn2(double base0, double base1, int n, ...) {
    va_list ap; va_start(ap, n);
    int x = va_arg(ap, int);
    va_end(ap);
    return (long long)(base0 * 1000.0) + (long long)(base1 * 100.0) + n * 10 + x;
}

extern long long bn_call1(double, int, int);
extern long long bn_call2(double, double, int, int);

int main(void) {
    int fails = 0;
    long long r1 = bn_call1(3.5, 2, 7);          /* 350 + 20 + 7 = 377 */
    long long r2 = bn_call2(1.5, 2.25, 4, 9);    /* 1500 + 225 + 40 + 9 = 1774 */
    printf("  vfn1: got=%lld want=377\n", r1);
    printf("  vfn2: got=%lld want=1774\n", r2);
    if (r1 != 377)  { fails++; }
    if (r2 != 1774) { fails++; }
    if (fails) { printf("%d FAILURE(S)\n", fails); return 1; }
    printf("ALL PASS\n"); return 0;
}
C

echo "Linking C driver + native arm32 facade, running under qemu-arm..."
if ! "$CC" -static -w "$TMP/driver.c" "$TMP/obj/a32vff.o" -o "$TMP/run" 2>"$TMP/link.err"; then
    echo "FAIL: link of C driver + native arm32 facade failed"
    head -8 "$TMP/link.err" | sed 's/^/    /'
    exit 1
fi

out="$("$QEMU_ARM" "$TMP/run" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
echo ""
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'ALL PASS'; then
    echo "=== native arm32 hard-float variadic __c_call (fixed float): PASS ==="
    exit 0
fi
echo "=== native arm32 hard-float variadic __c_call (fixed float): FAIL (rc=$rc) ==="
exit 1
