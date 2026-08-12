#!/bin/sh
# Runner: builder-comp_native_arm32_linux — identical to
# builder-comp_arm32_linux EXCEPT the main / test-runner module's IR→.o
# step goes through the NATIVE arm32 backend (pkg/binate/native/arm32) via
# `--backend native`, rather than codegen→clang -c (the LLVM path).  Dependency
# packages still go through LLVM; the native .o must link cleanly against them.
#
# arm-linux-gnueabihf is the HARD-float (AAPCS-VFP) ABI: applyTarget stamps
# types.SetFloatABI(FLOAT_ABI_HARD), so the native backend + codegen classify
# floats in VFP registers (hard-float ABI).  Like the LLVM sibling it
# links against the cross-glibc and runs under qemu-arm user-mode — NOT the
# freestanding semihosting path of builder-comp_native_arm32_baremetal.
#
# current-tree cmd/bnc (compiled via the BUILDER during runner_setup →
# GEN1_COMPILER) cross-compiles each conformance test for arm-linux-gnueabihf
# (32-bit ARMv7-A Linux, hard-float); the resulting binary runs under qemu-arm
# user-mode emulation.  Its LLVM sibling OVERRIDE_MODE (builder-comp_arm32_linux)
# supplies the shared ILP32 .expected / .xfail overrides (see conformance/run.sh).

. "$BINATE_DIR/scripts/lib/build-compilers.sh"
#
# Required toolchain (CI installs on ubuntu-latest; local dev see
# scripts/setup/arm32-linux-deps.sh):
#   - clang (host, with lld for cross-target ELF link)
#   - gcc-arm-linux-gnueabihf (cross binutils + libc6-armhf-cross +
#     libc6-dev-armhf-cross under /usr/arm-linux-gnueabihf/)
#   - qemu-user-static (qemu-arm-static / qemu-arm)

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
        echo "error: builder-comp_native_arm32_linux requires qemu-arm or qemu-arm-static" >&2
        echo "  Linux:  sudo apt-get install qemu-user-static" >&2
        echo "  macOS:  brew install qemu" >&2
        echo "  Override with QEMU_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_native_arm32_linux requires clang" >&2
        exit 2
    fi
    # Sanity check: clang can produce arm-linux-gnueabihf output (deps still go
    # through LLVM).  Catches a missing cross-toolchain early.
    if ! echo 'int main(void){return 0;}' | clang -target arm-linux-gnueabihf -march=armv7-a -x c -c - -o /tmp/_bn_narm32_probe.o 2>/dev/null; then
        echo "error: clang cannot target arm-linux-gnueabihf — install cross-toolchain" >&2
        echo "  Linux:  sudo apt-get install gcc-arm-linux-gnueabihf" >&2
        echo "  macOS:  no easy native path; use Docker or a Linux VM" >&2
        rm -f /tmp/_bn_narm32_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_narm32_probe.o
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
    # The ONLY substantive difference from builder-comp_arm32_linux: --backend
    # native routes the main/test module's IR→.o through pkg/binate/native/arm32
    # (deps still go via LLVM).  No -mfloat-abi=soft (hard-float) and no explicit
    # libgcc — clang's hosted gnueabihf link supplies AEABI helpers automatically.
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root" --target arm32-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" \
        --target arm32-linux --backend native --build-dir "$bdir" $BINATE_FLAGS \
        -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
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
