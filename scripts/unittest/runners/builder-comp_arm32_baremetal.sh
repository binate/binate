#!/bin/sh
# Runner: builder-comp_arm32_baremetal — current-tree cmd/bnc compiles
# each unit-test package for ARMv7-A bare-metal
# (--target arm32-baremetal).  The resulting ELF binary boots under
# `qemu-system-arm -M virt -semihosting`; test output goes through
# the semihosting console (SYS_WRITEC) and the binary exits via
# semihosting (SYS_EXIT_EXTENDED).
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
    build_gen1
}

# Compose the per-invocation bnc `--cflag` args from $BAREMETAL_LD_FLAGS (macOS
# `-fuse-ld=lld` for the ELF cross-link).  The AEABI runtime helpers once pulled
# from libgcc.a via `--link-after-objs` are now provided by
# runtime/baremetal_arm32/aeabi_{int,float}.s, so no libgcc pass is needed.
_baremetal_bnc_extra_args() {
    set --
    if [ -n "$BAREMETAL_LD_FLAGS" ]; then
        set -- "$@" --cflag "$BAREMETAL_LD_FLAGS"
    fi
    printf '%s\n' "$@"
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    # Read the extra args (one per line) into positional params.
    OLDIFS=$IFS; IFS='
'; set -- $(_baremetal_bnc_extra_args); IFS=$OLDIFS
    testbin=$("$GEN1_COMPILER" --test --target arm32-baremetal \
        --runtime "$BINATE_DIR/runtime/baremetal_arm32/crt0.s" \
        "$@" \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-baremetal)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target arm32-baremetal)" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    # Forward run.sh's per-test skip / shard filters to the compiled runner via the
    # QEMU command line: the `virt` machine exposes `-append` through semihosting
    # SYS_GET_CMDLINE, which pkg/builtins/startup installs as os.Args(), so the
    # generated runner honors --skip / --shard-index / --shard-count exactly as
    # cmd/bni --test does (SKIP_FILTER / TEST_SHARD_* are set by run.sh from the
    # <pkg>.skip.<mode> / <pkg>.split.<mode> markers).
    append=""
    [ -n "$SKIP_FILTER" ] && append="$append --skip $SKIP_FILTER"
    [ -n "$TEST_SHARD_COUNT" ] && \
        append="$append --shard-index $TEST_SHARD_IDX --shard-count $TEST_SHARD_COUNT"
    if [ -n "$append" ]; then
        "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
            -nographic -semihosting -no-reboot \
            -kernel "$testbin" -append "$append" 2>&1
    else
        "$QEMU_SYSTEM_ARM" -M virt -cpu cortex-a15 -m 16M \
            -nographic -semihosting -no-reboot \
            -kernel "$testbin" 2>&1
    fi
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
