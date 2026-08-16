#!/bin/sh
# Runner: builder-comp_arm32_baremetal — current-tree cmd/bnc (compiled
# via the BUILDER during runner_setup → GEN1_COMPILER) compiles each
# conformance test for ARMv7-A bare-metal (--target arm32-baremetal).
# The resulting ELF binary boots
# directly under `qemu-system-arm -M virt -semihosting` — no
# kernel, no libc, no argv — and the test's output goes
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

. "$BINATE_DIR/scripts/lib/build-compilers.sh"
. "$BINATE_DIR/scripts/lib/find-arm32-baremetal-toolchain.sh"

QEMU_SYSTEM_ARM="${QEMU_SYSTEM_ARM:-}"
if [ -z "$QEMU_SYSTEM_ARM" ]; then
    if command -v qemu-system-arm >/dev/null 2>&1; then
        QEMU_SYSTEM_ARM=qemu-system-arm
    fi
fi

runner_setup() {
    if [ -z "$QEMU_SYSTEM_ARM" ]; then
        echo "error: builder-comp_arm32_baremetal requires qemu-system-arm" >&2
        echo "  Linux:  sudo apt-get install qemu-system-arm" >&2
        echo "  macOS:  brew install qemu" >&2
        echo "  Override with QEMU_SYSTEM_ARM=<path>" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_arm32_baremetal requires clang" >&2
        exit 2
    fi
    # Sanity check: ensure clang can produce arm-none-eabi
    # objects + link them.  The link side fails out-of-the-box on
    # macOS (Apple `ld` is Mach-O only); ubuntu-latest's system
    # clang ships a working ARM target + lld combo.
    if ! echo 'int main(void){return 0;}' | clang -target arm-none-eabi -mfloat-abi=soft -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_baremetal_probe.o 2>/dev/null; then
        echo "error: clang cannot target arm-none-eabi" >&2
        rm -f /tmp/_bn_baremetal_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_baremetal_probe.o
    if [ -z "$BAREMETAL_LIBGCC_A" ]; then
        echo "error: boot-comp_arm32_baremetal requires arm-none-eabi libgcc.a" >&2
        echo "  Linux:  sudo apt-get install gcc-arm-none-eabi" >&2
        echo "  macOS:  brew install arm-none-eabi-gcc" >&2
        exit 2
    fi
    build_gen1
}

# Compose the host-specific bnc args: macOS needs `-fuse-ld=lld`
# (Apple's `ld` is Mach-O only); both apt and brew expose
# libgcc.a at host-specific paths so it's passed positionally via
# `--link-after-objs`.
_baremetal_bnc_extra_args() {
    set --
    if [ -n "$BAREMETAL_LD_FLAGS" ]; then
        set -- "$@" --cflag "$BAREMETAL_LD_FLAGS"
    fi
    set -- "$@" --link-after-objs "$BAREMETAL_LIBGCC_A"
    printf '%s\n' "$@"
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
    # BINATE_DIR is always passed FIRST so bnc's primaryRoot
    # (the first -I) resolves to the binate source root, which
    # is what arm32-baremetal's targetRuntimeFiles
    # (runtime/baremetal_arm32/crt0.s etc.) need.  For multi-
    # package tests, compile_root is the test's own dir;
    # AddBniPath dedups so passing BINATE_DIR twice when
    # compile_root == BINATE_DIR is a no-op.
    OLDIFS=$IFS; IFS='
'; set -- $(_baremetal_bnc_extra_args); IFS=$OLDIFS
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-baremetal)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target arm32-baremetal)" \
        -I "$compile_root" -L "$compile_root" --target arm32-baremetal \
        --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
        "$@" \
        --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # `-M virt -cpu cortex-a15` matches the linker script's
        # 0x40000000 RAM base.  `-nographic` routes the QEMU
        # console to stdout/stderr; `-semihosting` enables the
        # SYS_WRITEC + SYS_EXIT_EXTENDED handlers crt0 / pkg/builtins/rt
        # depend on.  `-kernel <ELF>` loads the binary; QEMU
        # finds the entry from its ELF header.  Wall-clock cap
        # via timeout(1) so a runaway test doesn't wedge the
        # sweep.
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 10 "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        else
            "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
                -nographic -semihosting -no-reboot \
                -kernel "$tmpbin" 2>&1 || true
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
