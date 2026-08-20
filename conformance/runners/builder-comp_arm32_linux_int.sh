#!/bin/sh
# Runner: builder-comp_arm32_linux_int — the bytecode VM on a 32-bit HOST.
#
# current-tree cmd/bnc (compiled via the BUILDER during runner_setup ->
# GEN1_COMPILER) CROSS-COMPILES cmd/bni itself to arm-linux-gnueabihf (32-bit
# ARMv7-A Linux), producing a 32-bit-host bytecode VM (host int == 4 bytes).
# Because cmd/bni bakes in ConfigForTarget("") (its own host config), that arm32
# bni interprets 32-bit-TARGET bytecode — so each conformance test's .bn is run
# through the VM ON A 32-BIT HOST, under qemu-arm user-mode emulation.  This is
# the configuration that exposes the VM's latent 32-bit-host bugs (int64/target-
# word handling) that the default -int legs (bni run NATIVELY on the 64-bit build
# host) cannot reach.
#
# Distinct from builder-comp_arm32_linux (which puts the compiled TEST PROGRAM on
# arm32): here the VM ITSELF is the arm32 binary and the test .bn stays bytecode.
#
# Required toolchain (same as builder-comp_arm32_linux; NOT available on macOS):
#   - clang (host) + gcc-arm-linux-gnueabihf cross-toolchain
#   - qemu-user-static (qemu-arm-static / qemu-arm)
# See scripts/setup/arm32-linux-deps.sh.

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
        echo "error: builder-comp_arm32_linux_int requires qemu-arm or qemu-arm-static" >&2
        echo "  Linux:  sudo apt-get install qemu-user-static" >&2
        echo "  macOS:  no user-mode qemu-arm; use Docker or a Linux VM" >&2
        echo "  Override with QEMU_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_arm32_linux_int requires clang" >&2
        exit 2
    fi
    # Ensure clang can produce arm-linux-gnueabihf output (catches a missing
    # cross-toolchain early rather than failing the bni cross-build cryptically).
    if ! echo 'int main(void){return 0;}' | clang -target arm-linux-gnueabihf -march=armv7-a -x c -c - -o /tmp/_bn_arm32int_probe.o 2>/dev/null; then
        echo "error: clang cannot target arm-linux-gnueabihf — install cross-toolchain" >&2
        echo "  Linux:  sudo apt-get install gcc-arm-linux-gnueabihf" >&2
        echo "  macOS:  no easy native path; use Docker or a Linux VM" >&2
        rm -f /tmp/_bn_arm32int_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_arm32int_probe.o
    # Cross-build the bytecode VM (bni) for arm32 -> $ARM32_INTERP.
    build_interp_arm32
}

runner_exec() {
    bn="$1"
    root="$2"
    # qemu-user shares the host filesystem, so the arm32 bni resolves the -I/-L
    # search paths (host directories) directly.  QEMU_LD_PREFIX points qemu at the
    # cross sysroot for the dynamic linker (/lib/ld-linux-armhf.so.3).
    QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-/usr/arm-linux-gnueabihf}"
    export QEMU_LD_PREFIX
    if [ -n "$root" ]; then
        ifaces="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$root")"
        impls="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$root")"
    else
        ifaces="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
        impls="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "$QEMU_ARM" "$ARM32_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$ifaces" -L "$impls" -main-file "$bn" 2>&1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 20 "$QEMU_ARM" "$ARM32_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$ifaces" -L "$impls" -main-file "$bn" 2>&1 || true
    else
        "$QEMU_ARM" "$ARM32_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$ifaces" -L "$impls" -main-file "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
