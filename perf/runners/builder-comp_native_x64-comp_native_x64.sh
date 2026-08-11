#!/bin/sh
# Runner: builder-comp_native_x64-comp_native_x64 — current-tree cmd/bnc
# (GEN1) compiles each perf test with `--backend native --target
# x86_64-linux` (pkg/binate/native/x64, SysV-AMD64 / ELF), then runs the
# produced binary natively on an x86_64 host (else under qemu-x86_64).  ELF
# sibling of the local-only native_x64_darwin; the amd64 half of the CI
# native perf coverage (with native_aa64).  Mirrors the conformance
# native_x64 runner's GEN1 + --backend native --target x86_64-linux path.
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
    # Probe that clang can build for x86_64-linux-gnu (needs the target libc
    # headers, which the real build's link against the target libc requires) —
    # catches a missing cross-libc early instead of per-test.
    if ! printf '#include <stdio.h>\nint main(void){return 0;}\n' \
            | clang -target x86_64-linux-gnu -x c -c - -o /tmp/_bn_x64_perf_probe.o 2>/dev/null; then
        echo "error: clang cannot target x86_64-linux-gnu" >&2
        echo "  Linux:  run on an x86_64 host (or apt install libc6-dev-amd64-cross)" >&2
        echo "  macOS:  brew install llvm  (Apple clang lacks cross-libc by default)" >&2
        rm -f /tmp/_bn_x64_perf_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_x64_perf_probe.o
    build_gen1
}

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target x86_64-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" \
        --backend native --target x86_64-linux -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    if host_is_x86_64; then
        set -- "$tmpbin"
    elif [ -n "$QEMU_X86_64" ]; then
        set -- "$QEMU_X86_64" "$tmpbin"
    else
        echo "RUN_SKIPPED: no qemu-x86_64 and host is not x86_64"
        return 0
    fi
    # Cap wall-clock so a runaway test (e.g. a codegen bug that loops) can't
    # wedge the sweep.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$@" 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 3 "$@" 2>&1
    else
        "$@" 2>&1
    fi
}

runner_cleanup() { cleanup_compilers; }
