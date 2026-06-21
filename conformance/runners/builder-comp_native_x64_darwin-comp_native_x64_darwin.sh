#!/bin/sh
# Runner: builder-comp_native_x64_darwin-comp_native_x64_darwin —
# current-tree cmd/bnc (built normally via the BUILDER during
# runner_setup) compiles each conformance test with `--backend native
# --target x86_64-darwin`, producing an x86-64 Mach-O executable.  On
# Apple Silicon the binary runs transparently under Rosetta; on an
# Intel Mac it runs natively.
#
# This is the macOS sibling of builder-comp_native_x64-comp_native_x64
# (which targets x86_64-linux / ELF and needs qemu-x86_64 off-x86_64).
# Its point: make the amd64 native backend end-to-end verifiable on a
# stock Apple-Silicon dev machine — no qemu, no Linux box — per
# explorations/plan-backend-objformat-decoupling.md.
#
# Like the ELF runner, this does NOT pre-build a native bnc: the amd64
# backend only lowers a subset of ops today, so most tests fail as
# COMPILE_ERROR.  That's the measurable starting point — the set
# shrinks as amd64 op-coverage lands.  Local-only by design (not in
# any CI modeset): Intel-macOS runners are scarce and the axis is
# already covered in CI by native_aa64 (Mach-O) + native_x64 (ELF).
#
# Required toolchain:
#   - macOS host (Mach-O executables don't run on Linux)
#   - clang able to target x86_64-apple-darwin (stock Apple clang does)
#   - Apple Silicon: Rosetta 2 (`softwareupdate --install-rosetta`)

. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# host_is_macos returns 0 (true) on a Darwin host.
host_is_macos() {
    case "$(uname -s)" in
        Darwin) return 0 ;;
        *) return 1 ;;
    esac
}

runner_setup() {
    if ! host_is_macos; then
        echo "error: builder-comp_native_x64_darwin requires a macOS host" >&2
        echo "  (Mach-O executables don't run on Linux; use" >&2
        echo "   builder-comp_native_x64-comp_native_x64 for ELF/Linux)" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_native_x64_darwin requires clang" >&2
        exit 2
    fi
    # Sanity probe: clang must be able to target x86_64-apple-darwin.
    if ! echo 'int main(void){return 0;}' | clang -target x86_64-apple-darwin -x c -c - -o /tmp/_bn_x64d_probe.o 2>/dev/null; then
        echo "error: clang cannot target x86_64-apple-darwin" >&2
        rm -f /tmp/_bn_x64d_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_x64d_probe.o
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
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root" --target x86_64-darwin)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" \
        --backend native --target x86_64-darwin --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" \
        $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # Direct exec: Rosetta runs the x86-64 Mach-O transparently on
        # Apple Silicon; an Intel Mac runs it natively.  Cap wall-clock
        # so a miscompiled infinite loop can't wedge the sweep.
        if command -v timeout >/dev/null 2>&1; then
            timeout 10 "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 10 "$tmpbin" 2>&1 || true
        else
            "$tmpbin" 2>&1 || true
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
