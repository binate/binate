#!/bin/sh
# Runner: builder-comp_arm32_baremetal — current-tree cmd/bnc compiles
# each unit-test package for ARMv7-A bare-metal
# (--target arm32-baremetal).  The resulting ELF binary boots under
# `qemu-system-arm -M virt -semihosting`; test output goes through
# pkg/bootstrap.Write (semihosting SYS_WRITEC), the binary exits via
# pkg/bootstrap.Exit (SYS_EXIT_EXTENDED).
#
# The BUILDER is used once during runner_setup to compile current
# cmd/bnc → GEN1_COMPILER; every per-test compile then goes through
# GEN1, so the "comp" link is always current-tree cmd/bnc.
#
# Toolchain requirements: see
# conformance/runners/builder-comp_arm32_baremetal.sh.
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

# Build the per-invocation `--cflag` / `--link-after-objs` args
# from $BAREMETAL_LD_FLAGS / $BAREMETAL_LIBGCC_A.  Stored in a
# function so the conformance runner can share the recipe.
_baremetal_bnc_extra_args() {
    set --
    if [ -n "$BAREMETAL_LD_FLAGS" ]; then
        set -- "$@" --cflag "$BAREMETAL_LD_FLAGS"
    fi
    set -- "$@" --link-after-objs "$BAREMETAL_LIBGCC_A"
    printf '%s\n' "$@"
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    # Read the extra args (one per line) into positional params.
    OLDIFS=$IFS; IFS='
'; set -- $(_baremetal_bnc_extra_args); IFS=$OLDIFS
    testbin=$("$GEN1_COMPILER" --test --target arm32-baremetal \
        "$@" \
        -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
        -nographic -semihosting -no-reboot \
        -kernel "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
