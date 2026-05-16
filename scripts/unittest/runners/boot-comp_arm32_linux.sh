#!/bin/sh
# Runner: boot-comp_arm32_linux — Bootstrap interprets bnc, which
# compiles each unit-test package for armv7-linux-gnueabihf via
# clang's `--target=armv7-linux-gnueabihf`.  The resulting binary is
# executed under qemu-arm user-mode emulation.  See
# conformance/runners/boot-comp_arm32_linux.sh for toolchain
# requirements and the v0 ARM32-Linux derisking plan rationale.

QEMU_ARM="${QEMU_ARM:-}"
if [ -z "$QEMU_ARM" ]; then
    if command -v qemu-arm-static >/dev/null 2>&1; then
        QEMU_ARM=qemu-arm-static
    elif command -v qemu-arm >/dev/null 2>&1; then
        QEMU_ARM=qemu-arm
    fi
fi

runner_setup() {
    if [ -z "$QEMU_ARM" ]; then
        echo "error: boot-comp_arm32_linux requires qemu-arm or qemu-arm-static" >&2
        echo "  Linux:  sudo apt-get install qemu-user-static" >&2
        echo "  macOS:  brew install qemu" >&2
        echo "  Override with QEMU_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: boot-comp_arm32_linux requires clang" >&2
        exit 2
    fi
    if ! echo 'int main(void){return 0;}' | clang -target armv7-linux-gnueabihf -x c -c - -o /tmp/_bn_arm32_probe.o 2>/dev/null; then
        echo "error: clang cannot target armv7-linux-gnueabihf — install cross-libc" >&2
        echo "  Linux:  sudo apt-get install libc6-armhf-cross linux-libc-dev-armhf-cross" >&2
        rm -f /tmp/_bn_arm32_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_arm32_probe.o
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    testbin=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --target arm32-linux --root "$BINATE_DIR" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$QEMU_ARM" "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() {
    : # nothing to clean up
}
