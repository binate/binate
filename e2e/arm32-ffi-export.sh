#!/bin/sh
# e2e/arm32-ffi-export.sh — native arm32 #[c_export] end-to-end.  A C program
# compiled in THUMB mode (the armhf default) passes a >16-byte struct BY VALUE to
# Binate #[c_export] functions built by the NATIVE arm32 backend, run under
# qemu-arm.  Exercises two native-arm32 mechanisms that nothing else covers:
#
#   1. the >16-byte by-value aggregate param adapter TRAMPOLINE — AAPCS32 splits
#      such an aggregate across r0-r3 + the stack, while Binate's internal
#      convention is a single pointer, so the entry re-marshals the args; and
#   2. ARM/Thumb INTERWORKING — the native functions are A32 (ARM) code, so a
#      Thumb caller's BL must be routed through an interworking veneer, which bfd
#      sets up only from the callee's STT_FUNC type (+ the .text "$a" mapping
#      symbol).  A regression in either shows up here as wrong output or a SIGILL.
#
# Neither is covered elsewhere: conformance is pure Binate (ARM->ARM, no Thumb
# caller), and e2e/ffi-export.sh's native check runs on the HOST arch, never
# native arm32.
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
// the stack; the trampoline gathers it into a pointer for the internal callee.
#[c_export("a32_big")]
func takeBig(x Big) int64 { return x.a + x.b + x.c }

// A big aggregate followed by a trailing scalar — the scalar's C-ABI slot and
// its internal slot differ (the aggregate shifts the register/stack cursor).
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

// A plain scalar export (no trampoline) — the pure interworking control: a Thumb
// caller reaching an ARM function needs STT_FUNC even with no aggregate param.
#[c_export("a32_add")]
func add(a int32, b int32) int32 { return a + b }
BN

echo "Compiling facade (--backend native --target arm32-linux)..."
mkdir -p "$TMP/obj"
if ! "$BNC" -I "$TMP/if:$A32_I" -L "$TMP/im:$A32_L" \
        --backend native --target arm32-linux --build-dir "$TMP/obj" --pkg a32ffi \
        >"$TMP/pkg.log" 2>&1 || [ ! -f "$TMP/obj/a32ffi.o" ]; then
    echo "FAIL: native arm32 facade compile (--pkg a32ffi) produced no object"
    tail -8 "$TMP/pkg.log" | sed 's/^/    /'
    exit 1
fi

# --- a Thumb C driver that passes the structs BY VALUE --------------------
cat > "$TMP/driver.c" <<'C'
#include <stdio.h>
struct Big { long long a, b, c; };
extern long long a32_big(struct Big);
extern long long a32_bigsmall(struct Big, int);
extern long long a32_narrowafter(struct Big, signed char);
extern struct Big a32_sretbig(struct Big);
extern int a32_add(int, int);

static int fails = 0;
static void chk(const char *n, long long got, long long want) {
    if (got == want) { printf("  %s: PASS (%lld)\n", n, got); }
    else { printf("  %s: FAIL got=%lld want=%lld\n", n, got, want); fails++; }
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
    if (fails) { printf("%d FAILURE(S)\n", fails); return 1; }
    printf("ALL PASS\n"); return 0;
}
C

echo "Linking Thumb C driver + native arm32 facade, running under qemu-arm..."
if ! "$CC" -mthumb -static -w "$TMP/driver.c" "$TMP/obj/a32ffi.o" -o "$TMP/run" \
        2>"$TMP/link.err"; then
    echo "FAIL: link of Thumb C driver + native arm32 facade failed"
    head -8 "$TMP/link.err" | sed 's/^/    /'
    exit 1
fi

out="$("$QEMU_ARM" "$TMP/run" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
echo ""
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qF 'ALL PASS'; then
    echo "=== native arm32 #[c_export] e2e: PASS ==="
    exit 0
fi
echo "=== native arm32 #[c_export] e2e: FAIL (rc=$rc) ==="
exit 1
