#!/bin/sh
# Runner: boot-comp_arm32_linux — Bootstrap interprets bnc, which
# compiles each conformance test for armv7-linux-gnueabihf (32-bit
# ARM Linux) via clang's `--target=armv7-linux-gnueabihf`.  The
# resulting binary is executed under qemu-arm user-mode emulation.
#
# Required toolchain (CI installs these on ubuntu-latest; for local
# dev see scripts/setup/arm32-linux-deps.sh):
#   - clang (host)
#   - libc6-armhf-cross + linux-libc-dev-armhf-cross  (sysroot)
#   - binutils-arm-linux-gnueabihf or clang's lld with --target
#   - qemu-user-static (provides qemu-arm-static / qemu-arm)
#
# Why this exists: validates the v0 ARM32-Linux derisking path end-
# to-end — type system at 32 bits, LLVM IR with intLL() = i32,
# binate_runtime.c with bn_int_t = int32, clang cross-compile, and
# QEMU user-mode execution.  See explorations/plan-arm32-bare-metal.md.

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
    # Sanity check: ensure clang can produce armv7-linux-gnueabihf
    # output.  This catches missing cross-libc early instead of
    # failing test-by-test.
    if ! echo 'int main(void){return 0;}' | clang -target armv7-linux-gnueabihf -x c -c - -o /tmp/_bn_arm32_probe.o 2>/dev/null; then
        echo "error: clang cannot target armv7-linux-gnueabihf — install cross-libc" >&2
        echo "  Linux:  sudo apt-get install libc6-armhf-cross linux-libc-dev-armhf-cross" >&2
        echo "  macOS:  no easy native path; use Docker or a Linux VM" >&2
        rm -f /tmp/_bn_arm32_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_arm32_probe.o
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
    BOOT_BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
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
    compile_out=$("$BOOT_BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- -I "$compile_root:$BOOT_BUILDER_LIB" -L "$compile_root:$BOOT_BUILDER_LIB" --target arm32-linux --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # Wall-clock cap via timeout(1) so a runaway test doesn't
        # wedge the sweep.
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

runner_cleanup() {
    : # nothing to clean up
}
