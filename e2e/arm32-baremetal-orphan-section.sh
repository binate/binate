#!/bin/sh
# e2e/arm32-baremetal-orphan-section.sh — an arm32-baremetal link fails on an input
# section its linker scripts do not name, rather than placing it on the heap.
#
# runtime/baremetal_arm32/baremetal_sections.ld names every section a bare-metal link
# expects, and bnc links with --orphan-handling=error: lld places a section no script
# names past .bss, which is where the heap (__heap_start) begins.  A program reads a
# buffer from an asm object linked with --link-after-objs:
#   - with the buffer in `.bss.<name>`, the link succeeds and the program runs;
#   - with it in `.noinit` (an allocated NOBITS section the scripts do not name), the
#     link must fail, naming the section.

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
    echo "SKIP: qemu-system-arm not found (needed to run the arm32-baremetal program)"
    exit 0
fi
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: clang not found"
    exit 0
fi
if ! echo 'int main(void){return 0;}' | "$CLANG" -target arm-none-eabi -mfloat-abi=soft \
        -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_e2e_probe_orphan.o 2>/dev/null; then
    echo "SKIP: clang cannot target arm-none-eabi"
    rm -f /tmp/_bn_e2e_probe_orphan.o
    exit 0
fi
rm -f /tmp/_bn_e2e_probe_orphan.o
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "SKIP: ld.lld (lld) not found (needed to link the arm32-baremetal program)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_orphan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- the asm objects: a 16-byte buffer, in a named section and in .noinit --------
for kind in bss noinit; do
    if [ "$kind" = bss ]; then
        section='.section .bss.e2e_buf,"aw",%nobits'
    else
        section='.section .noinit,"aw",%nobits'
    fi
    cat > "$TMP/buf_$kind.s" <<EOF
	.arch armv7-a
	$section
	.global e2e_buf
	.balign 4
e2e_buf:
	.space 16
EOF
done

# --- the Binate program: reads the buffer, so the link keeps its section ----------
cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	var p *uint8 = __c_global("e2e_buf", uint8)
	testing.Println(cast(int, p[0]) + 7)
}
EOF

# --- build gen1 bnc from current source -----------------------------------
GEN1="$TMP/gen1-bnc"
gen1_log="$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1)" || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed" >&2
    echo "$gen1_log" | tail -5 >&2
    exit 1
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-baremetal)"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target arm32-baremetal)"
LD_EXTRA=""
if [ "$(uname -s)" = "Darwin" ]; then LD_EXTRA="--cflag -fuse-ld=lld"; fi

# build <kind>: assemble buf_<kind>.s and compile + link the program with it,
# leaving the link's output in $TMP/<kind>.log; returns the link's status.
build() {
    mkdir -p "$TMP/build_$1"
    if ! "$CLANG" -target arm-none-eabi -march=armv7-a -mfloat-abi=soft -c \
            "$TMP/buf_$1.s" -o "$TMP/buf_$1.o" 2>"$TMP/as_$1.err"; then
        echo "FAIL: assembling buf_$1.s failed" >&2
        head -6 "$TMP/as_$1.err" >&2
        exit 1
    fi
    "$GEN1" -I "$IFACE" -L "$IMPL" -I "$BINATE_DIR" -L "$BINATE_DIR" \
            --target arm32-baremetal \
            --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
            $LD_EXTRA --link-after-objs "$TMP/buf_$1.o" \
            --build-dir "$TMP/build_$1" -o "$TMP/prog_$1" "$TMP/main.bn" >"$TMP/$1.log" 2>&1 \
            && [ -x "$TMP/prog_$1" ]
}

if ! build bss; then
    echo "FAIL: the program with its buffer in .bss.e2e_buf did not link" >&2
    tail -8 "$TMP/bss.log" >&2
    exit 1
fi
out="$(timeout 15 "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -semihosting \
        -no-reboot -kernel "$TMP/prog_bss" 2>&1)"
if [ "$out" != 7 ]; then
    echo "FAIL: the program with its buffer in .bss.e2e_buf printed: $out (want 7)" >&2
    exit 1
fi

if build noinit; then
    echo "FAIL: the program with its buffer in .noinit linked; an unnamed section must fail the link" >&2
    exit 1
fi
if ! grep -q "is being placed in '.noinit'" "$TMP/noinit.log"; then
    echo "FAIL: the link with a .noinit section failed for another reason:" >&2
    tail -8 "$TMP/noinit.log" >&2
    exit 1
fi

echo "PASS: an arm32-baremetal link takes a .bss.* buffer and fails on a .noinit one"
exit 0
