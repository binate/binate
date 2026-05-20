#!/bin/sh
# Runner: boot-comp_arm32_baremetal — Bootstrap interprets bnc,
# which compiles each conformance test for ARMv7-A bare-metal
# (--target arm32-baremetal).  The resulting ELF binary boots
# directly under `qemu-system-arm -M virt -semihosting` — no
# kernel, no libc, no argv — and the test's println output goes
# through SYS_WRITEC, with rt.Exit terminating via
# SYS_EXIT_EXTENDED.
#
# Required toolchain (CI installs these on ubuntu-latest):
#   - clang (host, with lld for cross-target ELF link)
#   - qemu-system-arm (provides the `virt` machine model)
#   - lld (LLVM linker, for cross-target ELF link)
# Optional:
#   - binutils-arm-none-eabi (`arm-none-eabi-{as,ld}`) if a different
#     assembler / linker is preferred over clang's defaults.

QEMU_SYSTEM_ARM="${QEMU_SYSTEM_ARM:-}"
if [ -z "$QEMU_SYSTEM_ARM" ]; then
    if command -v qemu-system-arm >/dev/null 2>&1; then
        QEMU_SYSTEM_ARM=qemu-system-arm
    fi
fi

runner_setup() {
    if [ -z "$QEMU_SYSTEM_ARM" ]; then
        echo "error: boot-comp_arm32_baremetal requires qemu-system-arm" >&2
        echo "  Linux:  sudo apt-get install qemu-system-arm" >&2
        echo "  macOS:  brew install qemu" >&2
        echo "  Override with QEMU_SYSTEM_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: boot-comp_arm32_baremetal requires clang" >&2
        exit 2
    fi
    # Sanity check: ensure clang can produce armv7a-none-eabi
    # objects + link them.  The link side fails out-of-the-box on
    # macOS (Apple `ld` is Mach-O only); ubuntu-latest's system
    # clang ships a working ARM target + lld combo.
    if ! echo 'int main(void){return 0;}' | clang -target armv7a-none-eabi -mfloat-abi=soft -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_baremetal_probe.o 2>/dev/null; then
        echo "error: clang cannot target armv7a-none-eabi" >&2
        rm -f /tmp/_bn_baremetal_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_baremetal_probe.o
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_${name}_$$"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$("$BOOT_BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- -I "$compile_root" -L "$compile_root" --target arm32-baremetal --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # `-M virt -cpu cortex-a15` matches the linker script's
        # 0x40000000 RAM base.  `-nographic` routes the QEMU
        # console to stdout/stderr; `-semihosting` enables the
        # SYS_WRITEC + SYS_EXIT_EXTENDED handlers crt0 / pkg/rt
        # depend on.  `-kernel <ELF>` loads the binary; QEMU
        # finds the entry from its ELF header.  Wall-clock cap
        # via timeout(1) so a runaway test doesn't wedge the
        # sweep.
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 1M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 10 "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 1M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        else
            "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 1M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() {
    : # nothing to clean up
}
