#!/bin/sh
# Runner: builder-comp_arm32_linux — current-tree cmd/bnc (compiled via
# the BUILDER during runner_setup → GEN1_COMPILER) cross-compiles
# each conformance test for arm-linux-gnueabihf (32-bit ARMv7-A
# Linux) via clang's `--target=arm-linux-gnueabihf -march=armv7-a`.
# The resulting binary is executed under qemu-arm user-mode emulation.

. "$BINATE_DIR/scripts/lib/build-compilers.sh"
#
# Required toolchain (CI installs these on ubuntu-latest; for local
# dev see scripts/setup/arm32-linux-deps.sh):
#   - clang (host)
#   - gcc-arm-linux-gnueabihf (pulls binutils-arm-linux-gnueabihf +
#     libc6-armhf-cross + libc6-dev-armhf-cross as deps; gives clang
#     a complete cross-toolchain it can auto-discover under
#     /usr/arm-linux-gnueabihf/)
#   - qemu-user-static (provides qemu-arm-static / qemu-arm)
#
# Why this exists: validates the v0 ARM32-Linux derisking path end-
# to-end — type system at 32 bits, LLVM IR with intLL() = i32,
# clang cross-compile, and QEMU user-mode execution.

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
    # Sanity check: ensure clang can produce arm-linux-gnueabihf
    # output.  Catches missing cross-toolchain early instead of
    # failing test-by-test.
    if ! echo 'int main(void){return 0;}' | clang -target arm-linux-gnueabihf -march=armv7-a -x c -c - -o /tmp/_bn_arm32_probe.o 2>/dev/null; then
        echo "error: clang cannot target arm-linux-gnueabihf — install cross-toolchain" >&2
        echo "  Linux:  sudo apt-get install gcc-arm-linux-gnueabihf" >&2
        echo "  macOS:  no easy native path; use Docker or a Linux VM" >&2
        rm -f /tmp/_bn_arm32_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_arm32_probe.o
    build_gen1
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="$(mktemp "${TMPDIR:-/tmp}/binate_conform_${name}_XXXXXX")"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root" --target arm32-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" \
        --target arm32-linux --build-dir "$bdir" $BINATE_FLAGS \
        -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # QEMU_LD_PREFIX points qemu-user at the cross-toolchain's
        # sysroot so it can resolve `/lib/ld-linux-armhf.so.3`
        # (the dynamic linker the binary asks for) under
        # /usr/arm-linux-gnueabihf/lib/.  Wall-clock cap via
        # timeout(1) so a runaway test doesn't wedge the sweep.
        QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-/usr/arm-linux-gnueabihf}"
        export QEMU_LD_PREFIX
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 "$QEMU_ARM" "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 10 "$QEMU_ARM" "$tmpbin" 2>&1 || true
        else
            "$QEMU_ARM" "$tmpbin" 2>&1 || true
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
