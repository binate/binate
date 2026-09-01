#!/bin/sh
# e2e/arm32-aeabi-dormant-helpers.sh — regression coverage for the arm32-baremetal
# AEABI helpers that NO Binate codegen ever emits, so the conformance/unittest
# suites never exercise them: the flag-setting float comparisons
# __aeabi_c{d,f}cmp{eq,le} / c{d,f}rcmple and the negates __aeabi_{d,f}neg.
#
# They exist only so a linked GCC/clang-compiled C object resolves.  To exercise
# them we link a hand-written ARM asm object whose `probe_*` functions call each
# helper the way a C caller would — materialising the flag-setting compares'
# result via the LO/LS/EQ/NE conditions — and __c_call them from a Binate program
# that prints each observable result.  The whole thing is cross-compiled for
# arm32-baremetal and run under qemu-system-arm (semihosting), matching the
# conformance native/LLVM arm32 setup.
#
# Only the LLVM arm32 path is exercised: __c_call is not yet supported by the
# native arm32 backend (it errors "native backend failed to emit object").  The
# helper asm is target runtime (aeabi_float.s), linked identically for both
# backends, so the LLVM path fully covers the helpers.
#
# Auto-discovered by .github/workflows/e2e-tests.yml.  SKIPs unless a
# qemu-system-arm + clang(arm-none-eabi) + lld toolchain is present.  The e2e
# workflow installs these for the arm32 scripts on the Linux lane, so it RUNS
# there; it SKIPs on macOS (targeted to linux-x64) and anywhere the toolchain is
# absent.
#
# Exit 0 on pass (including a graceful SKIP when the toolchain is absent);
# non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || echo clang)}"
QEMU="${QEMU_SYSTEM_ARM:-$(command -v qemu-system-arm || true)}"

# --- prerequisite probe (SKIP, not FAIL, when unavailable) ----------------
if [ -z "$QEMU" ]; then
    echo "SKIP: qemu-system-arm not found (needed to run the arm32-baremetal probe)"
    exit 0
fi
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: clang not found"
    exit 0
fi
if ! echo 'int main(void){return 0;}' | "$CLANG" -target arm-none-eabi -mfloat-abi=soft \
        -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_e2e_probe.o 2>/dev/null; then
    echo "SKIP: clang cannot target arm-none-eabi"
    rm -f /tmp/_bn_e2e_probe.o
    exit 0
fi
rm -f /tmp/_bn_e2e_probe.o
# The baremetal link uses ld.lld (clang -fuse-ld=lld); the compile-only probe above
# would pass without it and then FAIL at the link, so gate on it too.
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "SKIP: ld.lld (lld) not found (needed to link the arm32-baremetal probe)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_aeabi.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/b"

# --- the asm probes: call each dormant helper the way a C caller would -----
# Compare probes return the derived boolean; neg probes tail-call the helper.
cat > "$TMP/probes.s" <<'EOF'
	.arch armv7-a
	.text

// double compares: a in r0:r1, b in r2:r3 -> int in r0.
	.global d_lt
d_lt:	push {lr}
	bl __aeabi_cdcmple
	movcc r0, #1        @ C==0 (LO): ordered and a<b
	movcs r0, #0
	pop {pc}
	.global d_le
d_le:	push {lr}
	bl __aeabi_cdcmple
	movls r0, #1        @ C==0 || Z==1 (LS): a<=b
	movhi r0, #0
	pop {pc}
	.global d_eq
d_eq:	push {lr}
	bl __aeabi_cdcmpeq
	moveq r0, #1        @ Z==1
	movne r0, #0
	pop {pc}
	.global d_ne
d_ne:	push {lr}
	bl __aeabi_cdcmpeq
	movne r0, #1        @ Z==0 (includes unordered)
	moveq r0, #0
	pop {pc}
	.global d_gt
d_gt:	push {lr}
	bl __aeabi_cdrcmple @ reversed: sets flags for b<=a
	movcc r0, #1        @ C==0: ordered and a>b
	movcs r0, #0
	pop {pc}
	.global d_ge
d_ge:	push {lr}
	bl __aeabi_cdrcmple
	movls r0, #1        @ a>=b
	movhi r0, #0
	pop {pc}

// float compares: a in r0, b in r1 -> int in r0.
	.global f_lt
f_lt:	push {lr}
	bl __aeabi_cfcmple
	movcc r0, #1
	movcs r0, #0
	pop {pc}
	.global f_le
f_le:	push {lr}
	bl __aeabi_cfcmple
	movls r0, #1
	movhi r0, #0
	pop {pc}
	.global f_eq
f_eq:	push {lr}
	bl __aeabi_cfcmpeq
	moveq r0, #1
	movne r0, #0
	pop {pc}
	.global f_gt
f_gt:	push {lr}
	bl __aeabi_cfrcmple
	movcc r0, #1
	movcs r0, #0
	pop {pc}

// negates: bit pattern in / out (double r0:r1, float r0).
	.global d_neg
d_neg:	b __aeabi_dneg
	.global f_neg
f_neg:	b __aeabi_fneg
EOF

# --- the Binate driver: __c_call each probe, print each observable result --
cat > "$TMP/main.bn" <<'EOF'
package "main"
import "pkg/builtins/testing"

// Bit patterns (double / float) fed as uint64 / uint32 (same registers the
// AEABI helpers use for a double / float).
func main() {
	var one uint64 = 0x3FF0000000000000
	var two uint64 = 0x4000000000000000
	var nan uint64 = 0x7FF8000000000000
	var pinf uint64 = 0x7FF0000000000000
	var pzero uint64 = 0x0000000000000000
	var nzero uint64 = 0x8000000000000000

	// less
	testing.Println(__c_call("d_lt", int, one, two))   // 1
	testing.Println(__c_call("d_lt", int, two, one))   // 0
	testing.Println(__c_call("d_lt", int, one, one))   // 0
	testing.Println(__c_call("d_lt", int, nan, one))   // 0  unordered
	testing.Println(__c_call("d_lt", int, one, nan))   // 0
	testing.Println(__c_call("d_lt", int, nzero, pzero)) // 0  -0 < +0 is false
	// less-or-equal
	testing.Println(__c_call("d_le", int, one, two))   // 1
	testing.Println(__c_call("d_le", int, two, one))   // 0
	testing.Println(__c_call("d_le", int, one, one))   // 1
	testing.Println(__c_call("d_le", int, nan, one))   // 0
	testing.Println(__c_call("d_le", int, nzero, pzero)) // 1  -0 <= +0
	// equal
	testing.Println(__c_call("d_eq", int, one, one))   // 1
	testing.Println(__c_call("d_eq", int, one, two))   // 0
	testing.Println(__c_call("d_eq", int, nan, nan))   // 0
	testing.Println(__c_call("d_eq", int, nzero, pzero)) // 1  -0 == +0
	// not-equal
	testing.Println(__c_call("d_ne", int, one, one))   // 0
	testing.Println(__c_call("d_ne", int, one, two))   // 1
	testing.Println(__c_call("d_ne", int, nan, nan))   // 1  unordered
	// greater
	testing.Println(__c_call("d_gt", int, two, one))   // 1
	testing.Println(__c_call("d_gt", int, one, two))   // 0
	testing.Println(__c_call("d_gt", int, one, one))   // 0
	testing.Println(__c_call("d_gt", int, nan, one))   // 0
	testing.Println(__c_call("d_gt", int, pinf, two))  // 1  inf > 2
	// greater-or-equal
	testing.Println(__c_call("d_ge", int, two, one))   // 1
	testing.Println(__c_call("d_ge", int, one, two))   // 0
	testing.Println(__c_call("d_ge", int, one, one))   // 1
	testing.Println(__c_call("d_ge", int, nan, one))   // 0
	testing.Println(__c_call("d_ge", int, nzero, pzero)) // 1

	// float32 (representative)
	var f1 uint32 = 0x3F800000
	var f2 uint32 = 0x40000000
	var fnan uint32 = 0x7FC00000
	testing.Println(__c_call("f_lt", int, f1, f2))     // 1
	testing.Println(__c_call("f_lt", int, fnan, f1))   // 0
	testing.Println(__c_call("f_le", int, f1, f1))     // 1
	testing.Println(__c_call("f_eq", int, f1, f1))     // 1
	testing.Println(__c_call("f_eq", int, fnan, fnan)) // 0
	testing.Println(__c_call("f_gt", int, f2, f1))     // 1
	testing.Println(__c_call("f_gt", int, fnan, f1))   // 0

	// negates (check the exact returned bit pattern)
	testing.Println(b2i(__c_call("d_neg", uint64, one) == 0xBFF0000000000000))   // 1  -1.0
	testing.Println(b2i(__c_call("d_neg", uint64, pzero) == nzero))              // 1  +0 -> -0
	testing.Println(b2i(__c_call("d_neg", uint64, pinf) == 0xFFF0000000000000))  // 1  +inf -> -inf
	testing.Println(b2i(__c_call("f_neg", uint32, f1) == cast(uint32, 0xBF800000))) // 1
	testing.Println(b2i(__c_call("f_neg", uint32, cast(uint32, 0)) == cast(uint32, 0x80000000))) // 1
}

func b2i(x bool) int {
	if x {
		return 1
	}
	return 0
}
EOF

WANT="$(printf '%s\n' \
	1 0 0 0 0 0 \
	1 0 1 0 1 \
	1 0 0 1 \
	0 1 1 \
	1 0 0 0 1 \
	1 0 1 0 1 \
	1 0 1 1 0 1 0 \
	1 1 1 1 1)"

# --- build gen1 bnc from current source -----------------------------------
GEN1="$TMP/gen1-bnc"
gen1_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1)" || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed" >&2
    echo "$gen1_log" | tail -5 >&2
    exit 1
fi

# --- assemble the probes, compile+link the Binate program, run under qemu --
if ! "$CLANG" -target arm-none-eabi -march=armv7-a -mfloat-abi=soft -c \
        "$TMP/probes.s" -o "$TMP/probes.o" 2>"$TMP/as.err"; then
    echo "FAIL: assembling probes.s failed" >&2
    head -6 "$TMP/as.err" >&2
    exit 1
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-baremetal)"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target arm32-baremetal)"
LD_EXTRA=""
if [ "$(uname -s)" = "Darwin" ]; then LD_EXTRA="--cflag -fuse-ld=lld"; fi

if ! "$GEN1" -I "$IFACE" -L "$IMPL" -I "$BINATE_DIR" -L "$BINATE_DIR" \
        --target arm32-baremetal \
        --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
        $LD_EXTRA --link-after-objs "$TMP/probes.o" \
        --build-dir "$TMP/b" -o "$TMP/run" "$TMP/main.bn" >"$TMP/comp.log" 2>&1 \
        || [ ! -x "$TMP/run" ]; then
    echo "FAIL: compile/link of the arm32-baremetal probe program failed" >&2
    tail -8 "$TMP/comp.log" >&2
    exit 1
fi

GOT="$(timeout 15 "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -semihosting \
        -no-reboot -kernel "$TMP/run" 2>&1)"

if [ "$GOT" = "$WANT" ]; then
    n=$(printf '%s\n' "$GOT" | grep -c .)
    echo "PASS: arm32 AEABI dormant helpers (cdcmp*/cfcmp*/dneg/fneg) — $n checks match under qemu"
    exit 0
fi

echo "FAIL: arm32 AEABI dormant-helper output mismatch" >&2
echo "--- got ---"  >&2; printf '%s\n' "$GOT"  >&2
echo "--- want ---" >&2; printf '%s\n' "$WANT" >&2
# show the first differing lines for convenience (temp files, not <(...), so the
# diagnostic works under a POSIX /bin/sh — e.g. dash on the Linux CI runner)
printf '%s\n' "$WANT" > "$TMP/want"
printf '%s\n' "$GOT"  > "$TMP/got"
diff "$TMP/want" "$TMP/got" 2>/dev/null | head -12 >&2
exit 1
