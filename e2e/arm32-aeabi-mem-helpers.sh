#!/bin/sh
# e2e/arm32-aeabi-mem-helpers.sh — regression coverage for the arm32-baremetal
# AEABI memory helpers (__aeabi_memcpy / memmove / memset / memclr and their
# 4 / 8 forms, runtime/baremetal_arm32/semihost.s).
#
# LLVM's ARM EABI backend lowers its memory intrinsics to these, notably at -O1
# and above, where clang's optimizer turns a zeroing loop or a run of zero stores
# into one (rt.MemZero's own loop included) — so a bare-metal program built at
# -O2 does not link without them.  Two checks:
#   1. a hand-written ARM asm object's `probe_*` functions call each helper the
#      way a C caller would (each argument order — memset's n and c are swapped
#      relative to memset — and each 4 / 8 form), and a Binate program __c_calls
#      them on buffers and prints the bytes;
#   2. the same program, built at -O2 — whose runtime's zero-fills become
#      __aeabi_memclr calls (checked in the runtime's object) — links and
#      prints the same.
# Both are cross-compiled for arm32-baremetal and run under qemu-system-arm
# (semihosting), matching the conformance LLVM arm32 setup.  Only the LLVM path:
# __c_call is not yet supported by the native arm32 backend, and the helpers are
# target runtime linked identically for both backends.
#
# Auto-discovered by .github/workflows/e2e-tests.yml.  SKIPs unless a
# qemu-system-arm + clang(arm-none-eabi) + lld toolchain is present.
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
        -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_e2e_probe_mem.o 2>/dev/null; then
    echo "SKIP: clang cannot target arm-none-eabi"
    rm -f /tmp/_bn_e2e_probe_mem.o
    exit 0
fi
rm -f /tmp/_bn_e2e_probe_mem.o
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "SKIP: ld.lld (lld) not found (needed to link the arm32-baremetal probe)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_aeabi_mem.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/b0" "$TMP/b2"

# --- the asm probes: tail-call each helper with the caller's arguments -----
cat > "$TMP/probes.s" <<'EOF'
	.arch armv7-a
	.text

// (dest, n)
	.global probe_memclr
probe_memclr:	b __aeabi_memclr
	.global probe_memclr4
probe_memclr4:	b __aeabi_memclr4
	.global probe_memclr8
probe_memclr8:	b __aeabi_memclr8

// (dest, n, c)
	.global probe_memset
probe_memset:	b __aeabi_memset
	.global probe_memset4
probe_memset4:	b __aeabi_memset4
	.global probe_memset8
probe_memset8:	b __aeabi_memset8

// (dest, src, n)
	.global probe_memcpy
probe_memcpy:	b __aeabi_memcpy
	.global probe_memcpy4
probe_memcpy4:	b __aeabi_memcpy4
	.global probe_memcpy8
probe_memcpy8:	b __aeabi_memcpy8
	.global probe_memmove
probe_memmove:	b __aeabi_memmove
	.global probe_memmove4
probe_memmove4:	b __aeabi_memmove4
	.global probe_memmove8
probe_memmove8:	b __aeabi_memmove8
EOF

# --- the Binate driver: __c_call each probe, print the bytes it touched ----
cat > "$TMP/main.bn" <<'EOF'
package "main"
import "pkg/builtins/testing"

func main() {
	var a [16]uint8
	for i := 0; i < 16; i++ {
		a[i] = cast(uint8, i + 1)
	}
	__c_call("probe_memclr", "void", &a[0], 5)
	testing.Println(cast(int, a[0]) + cast(int, a[4]) * 100 + cast(int, a[5]) * 10000) // 60000
	__c_call("probe_memset", "void", &a[0], 3, 65)
	testing.Println(cast(int, a[2]) * 1000 + cast(int, a[3])) // 65000
	var b [16]uint8
	for i := 0; i < 16; i++ {
		b[i] = 9
	}
	__c_call("probe_memcpy", "void", &b[0], &a[0], 4)
	testing.Println(cast(int, b[2]) * 1000 + cast(int, b[3]) * 10 + cast(int, b[4])) // 65009
	// a = 65 65 65 0 0 6 7 8 ...; move a[0..5] up one byte (overlapping)
	__c_call("probe_memmove", "void", &a[1], &a[0], 6)
	testing.Println(cast(int, a[3]) * 10000 + cast(int, a[6]) * 100 + cast(int, a[7])) // 650608

	var w [4]uint64
	for i := 0; i < 4; i++ {
		w[i] = cast(uint64, 0x0101010101010101)
	}
	__c_call("probe_memclr4", "void", &w[0], 8)
	__c_call("probe_memclr8", "void", &w[1], 8)
	testing.Println(w[0] == 0 && w[1] == 0 && w[2] == cast(uint64, 0x0101010101010101)) // true
	__c_call("probe_memset4", "void", &w[0], 8, 2)
	__c_call("probe_memset8", "void", &w[1], 8, 3)
	testing.Println(w[0] == cast(uint64, 0x0202020202020202) && w[1] == cast(uint64, 0x0303030303030303)) // true
	__c_call("probe_memcpy4", "void", &w[2], &w[0], 8)
	__c_call("probe_memcpy8", "void", &w[3], &w[1], 8)
	testing.Println(w[2] == cast(uint64, 0x0202020202020202) && w[3] == cast(uint64, 0x0303030303030303)) // true
	// w = 02.. 03.. 02.. 03..; overlapping moves, up and down by one word
	__c_call("probe_memmove4", "void", &w[1], &w[0], 16)
	testing.Println(w[1] == cast(uint64, 0x0202020202020202) && w[2] == cast(uint64, 0x0303030303030303)) // true
	__c_call("probe_memmove8", "void", &w[0], &w[1], 16)
	testing.Println(w[0] == cast(uint64, 0x0202020202020202) && w[1] == cast(uint64, 0x0303030303030303)) // true
}
EOF

WANT="$(printf '%s\n' 60000 65000 65009 650608 true true true true true)"

# --- build gen1 bnc from current source -----------------------------------
GEN1="$TMP/gen1-bnc"
gen1_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1)" || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed" >&2
    echo "$gen1_log" | tail -5 >&2
    exit 1
fi

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

# build_and_run <opt flag> <build dir> <output>: compile+link at that level and
# run under qemu, leaving the program's output in RUN_OUT.
build_and_run() {
    if ! "$GEN1" $1 -I "$IFACE" -L "$IMPL" -I "$BINATE_DIR" -L "$BINATE_DIR" \
            --target arm32-baremetal \
            --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
            $LD_EXTRA --link-after-objs "$TMP/probes.o" \
            --build-dir "$2" -o "$3" "$TMP/main.bn" >"$TMP/comp.log" 2>&1 \
            || [ ! -x "$3" ]; then
        echo "FAIL: compile/link of the arm32-baremetal probe program failed ($1)" >&2
        tail -8 "$TMP/comp.log" >&2
        exit 1
    fi
    RUN_OUT="$(timeout 15 "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -semihosting \
            -no-reboot -kernel "$3" 2>&1)"
}

for level in -O0 -O2; do
    build_and_run "$level" "$TMP/b${level#-O}" "$TMP/run${level#-O}"
    # At -O2 the runtime itself must call the helpers (not only the probes),
    # or this leg would stay green without exercising what it is for.  A
    # linked build removes its objects, so compile them once more, to objects.
    if [ "$level" = -O2 ]; then
        mkdir -p "$TMP/c2"
        "$GEN1" -O2 -c -I "$IFACE" -L "$IMPL" -I "$BINATE_DIR" -L "$BINATE_DIR" \
                --target arm32-baremetal --build-dir "$TMP/c2" -o "$TMP/c2/main" \
                "$TMP/main.bn" >"$TMP/c2.log" 2>&1
        if ! grep -q __aeabi_memclr "$TMP/c2/pkg__builtins__rt.o" 2>/dev/null; then
            echo "FAIL: the -O2 runtime object does not reference __aeabi_memclr" >&2
            tail -4 "$TMP/c2.log" >&2
            exit 1
        fi
    fi
    if [ "$RUN_OUT" != "$WANT" ]; then
        echo "FAIL: arm32 AEABI memory-helper output mismatch ($level)" >&2
        echo "--- got ---"  >&2; printf '%s\n' "$RUN_OUT" >&2
        echo "--- want ---" >&2; printf '%s\n' "$WANT" >&2
        exit 1
    fi
done
echo "PASS: arm32 AEABI memory helpers (memcpy/memmove/memset/memclr and 4/8 forms) at -O0 and -O2 under qemu"
exit 0
