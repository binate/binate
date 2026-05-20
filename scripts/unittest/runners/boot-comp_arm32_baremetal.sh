#!/bin/sh
# Runner: boot-comp_arm32_baremetal — Bootstrap interprets bnc,
# which compiles each unit-test package for ARMv7-A bare-metal
# (--target arm32-baremetal).  The resulting ELF binary boots
# under `qemu-system-arm -M virt -semihosting`; test output goes
# through pkg/bootstrap.Write (semihosting SYS_WRITEC), the
# binary exits via pkg/bootstrap.Exit (SYS_EXIT_EXTENDED).
#
# Toolchain requirements: see
# conformance/runners/boot-comp_arm32_baremetal.sh.

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
    if ! echo 'int main(void){return 0;}' | clang -target armv7a-none-eabi -mfloat-abi=soft -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_baremetal_probe.o 2>/dev/null; then
        echo "error: clang cannot target armv7a-none-eabi" >&2
        rm -f /tmp/_bn_baremetal_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_baremetal_probe.o
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    # cd / — see runners/boot.sh for the CLI-disambiguation rationale.
    testbin=$(cd / && "$BOOT_BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --target arm32-baremetal --root "$BINATE_DIR" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 1M \
        -nographic -semihosting -no-reboot \
        -kernel "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() {
    : # nothing to clean up
}
