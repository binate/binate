#!/bin/sh
# Runner: builder-comp_native_x64-comp_native_x64 — current-tree cmd/bnc
# (built via the LLVM path -> GEN1 in runner_setup) compiles each unit-test
# package with `--test --backend native --target x86_64-linux`, routing
# through pkg/binate/native/x64.EmitObject (a full SysV-AMD64 / ELF backend),
# then runs the produced test binary (natively on an x86_64 host, else under
# qemu-x86_64).  ELF sibling of the local-only native_x64_darwin (Mach-O);
# with native_aa64 this is the CI arch+format unit coverage
# (plan-backend-objformat-decoupling.md).
#
# Like the conformance native_x64 runner, this drives GEN1 (the LLVM-built
# bnc) per package rather than a bnc pre-built with the native backend.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

QEMU_X86_64="${QEMU_X86_64:-}"
if [ -z "$QEMU_X86_64" ]; then
    if command -v qemu-x86_64-static >/dev/null 2>&1; then
        QEMU_X86_64=qemu-x86_64-static
    elif command -v qemu-x86_64 >/dev/null 2>&1; then
        QEMU_X86_64=qemu-x86_64
    fi
fi

# host_is_x86_64 returns 0 (true) if running on x86_64.
host_is_x86_64() {
    case "$(uname -m)" in
        x86_64|amd64) return 0 ;;
        *) return 1 ;;
    esac
}

runner_setup() {
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_native_x64 requires clang" >&2
        exit 2
    fi
    # Probe that clang can actually build for x86_64-linux-gnu.  Include
    # <stdio.h> so the probe needs the target libc headers — the real build
    # links against the target libc, and a header-free TU compiles even when
    # the cross-libc is absent, then the per-test build fails.
    if ! printf '#include <stdio.h>\nint main(void){return 0;}\n' \
            | clang -target x86_64-linux-gnu -x c -c - -o /tmp/_bn_x64_unit_probe.o 2>/dev/null; then
        echo "error: clang cannot target x86_64-linux-gnu" >&2
        echo "  Linux:  run on an x86_64 host (or apt install libc6-dev-amd64-cross)" >&2
        echo "  macOS:  brew install llvm  (Apple clang lacks cross-libc by default)" >&2
        rm -f /tmp/_bn_x64_unit_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_x64_unit_probe.o
    build_gen1
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    testbin=$("$GEN1_COMPILER" --test --backend native --target x86_64-linux -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target x86_64-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # compile/link error output
        rm -rf "$bdir"
        return 1
    fi
    if host_is_x86_64; then
        "$testbin" 2>&1
        rc=$?
    elif [ -n "$QEMU_X86_64" ]; then
        "$QEMU_X86_64" "$testbin" 2>&1
        rc=$?
    else
        echo "RUN_SKIPPED: no qemu-x86_64 and host is not x86_64"
        rc=0
    fi
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
