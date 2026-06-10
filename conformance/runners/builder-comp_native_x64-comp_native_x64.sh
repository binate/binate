#!/bin/sh
# Runner: builder-comp_native_x64-comp_native_x64 — current-tree
# cmd/bnc (compiled normally via the BUILDER during runner_setup)
# compiles each conformance test with `--backend native --target
# x86_64-linux`.  The result lands in pkg/binate/native/x64.EmitObject,
# which is a Phase 2 stub returning false — every test currently
# fails as COMPILE_ERROR, which is the measurable starting point
# for Phase 3's per-op lowering work.
#
# Note: unlike builder-comp_native_aa64-comp_native_aa64, this
# runner does NOT pre-build bnc with `--backend native` (which
# would need to succeed, but the stub backend can't produce a
# working bnc binary).  Once Phase 3 lowering covers cmd/bnc's
# transitive deps, switch to the bnc-native-prebuilt shape for
# the amortization win.
#
# Required toolchain for the produced binaries (Phase 3+):
#   - clang (host)
#   - on Linux x86_64: nothing extra (host runs the binary)
#   - on macOS arm64 / non-x86_64 host: qemu-x86_64 (brew install qemu)

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
    # Sanity probe: clang must be able to target x86_64-linux-gnu.
    # Catches missing cross-toolchain early instead of failing per-test.
    if ! echo 'int main(void){return 0;}' | clang -target x86_64-linux-gnu -x c -c - -o /tmp/_bn_x64_probe.o 2>/dev/null; then
        echo "error: clang cannot target x86_64-linux-gnu" >&2
        echo "  Linux:  apt install libc6-dev-amd64-cross  (or run on an x86_64 host)" >&2
        echo "  macOS:  brew install llvm  (Apple clang lacks cross-libc by default)" >&2
        rm -f /tmp/_bn_x64_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_x64_probe.o
    build_gen1
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
    compile_out=$("$GEN1_COMPILER" -I "$compile_root:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$compile_root:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
        --backend native --target x86_64-linux --runtime "$BINATE_DIR/runtime/binate_runtime.c" --build-dir "$bdir" \
        $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # Host vs cross: x86_64 host runs natively, anything else
        # routes through qemu-x86_64 user-mode emulation.
        if host_is_x86_64; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 10 "$tmpbin" 2>&1 || true
            elif command -v gtimeout >/dev/null 2>&1; then
                gtimeout 10 "$tmpbin" 2>&1 || true
            else
                "$tmpbin" 2>&1 || true
            fi
        elif [ -n "$QEMU_X86_64" ]; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 10 "$QEMU_X86_64" "$tmpbin" 2>&1 || true
            elif command -v gtimeout >/dev/null 2>&1; then
                gtimeout 10 "$QEMU_X86_64" "$tmpbin" 2>&1 || true
            else
                "$QEMU_X86_64" "$tmpbin" 2>&1 || true
            fi
        else
            echo "RUN_SKIPPED: no qemu-x86_64 and host is not x86_64"
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
