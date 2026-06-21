#!/bin/sh
# Runner: builder-comp_arm32_linux — current-tree cmd/bnc cross-compiles
# each unit-test package for arm-linux-gnueabihf (ARMv7-A); the resulting
# binary runs under qemu-arm user-mode emulation.  See
# conformance/runners/builder-comp_arm32_linux.sh for toolchain
# requirements and the v0 ARM32-Linux derisking plan rationale.
# The BUILDER is used once during runner_setup to compile current
# cmd/bnc → GEN1_COMPILER; every per-test compile then goes through
# GEN1, so the "comp" link is always current-tree cmd/bnc.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

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
        echo "error: builder-comp_arm32_linux requires qemu-arm or qemu-arm-static" >&2
        echo "  Linux:  sudo apt-get install qemu-user-static" >&2
        echo "  macOS:  brew install qemu" >&2
        echo "  Override with QEMU_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_arm32_linux requires clang" >&2
        exit 2
    fi
    if ! echo 'int main(void){return 0;}' | clang -target arm-linux-gnueabihf -march=armv7-a -x c -c - -o /tmp/_bn_arm32_probe.o 2>/dev/null; then
        echo "error: clang cannot target arm-linux-gnueabihf — install cross-toolchain" >&2
        echo "  Linux:  sudo apt-get install gcc-arm-linux-gnueabihf" >&2
        rm -f /tmp/_bn_arm32_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_arm32_probe.o
    build_gen1
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    testbin=$("$GEN1_COMPILER" --test --target arm32-linux \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    # QEMU_LD_PREFIX points qemu-user at the cross-toolchain's
    # sysroot so it can find the ARM dynamic linker
    # (`/lib/ld-linux-armhf.so.3` from the binary's perspective →
    # `/usr/arm-linux-gnueabihf/lib/ld-linux-armhf.so.3` on the
    # host).  Defaulted only when the caller hasn't set it.
    QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-/usr/arm-linux-gnueabihf}" \
        "$QEMU_ARM" "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
