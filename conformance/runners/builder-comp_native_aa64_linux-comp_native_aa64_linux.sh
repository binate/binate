#!/bin/sh
# Runner: builder-comp_native_aa64_linux-comp_native_aa64_linux — current-tree
# cmd/bnc (compiled normally via the BUILDER during runner_setup) compiles each
# conformance test with `--backend native --target aarch64-linux`, routing
# through pkg/binate/native/aarch64.EmitObject targeting the AArch64 Linux ELF
# ABI, then runs the produced binary (natively on aarch64, else under
# qemu-aarch64).
#
# This is the AArch64/Linux/ELF sibling of
# builder-comp_native_aa64-comp_native_aa64 (which is AArch64/macOS/Mach-O), and
# the FIRST mode to exercise the aarch64 native backend's ELF output end-to-end:
# the aarch64 ELF data + GOT relocations (R_AARCH64_ADD_ABS_LO12_NC /
# LDST64_ABS_LO12_NC / ADR_GOT_PAGE / LD64_GOT_LO12_NC, landed `9e866a43`) were
# until now only clang-cross-verified, never link+run-verified.
#
# EXPERIMENTAL / red-signal: the aarch64-linux native path has never been run,
# so failures are expected until it is built out (this mode is what surfaces
# them + drives the xfail set / fixes).  Marked experimental in
# .github/workflows/conformance-tests.yml (continue-on-error), NOT in
# scripts/modesets/all.
#
# Required toolchain for the produced binaries:
#   - clang (host)
#   - on Linux aarch64: nothing extra (host runs the binary)
#   - on x86_64 / non-aarch64 host: gcc-aarch64-linux-gnu (cross-libc + cross-ld,
#     which clang -target aarch64-linux-gnu auto-discovers, as for arm32) plus
#     qemu-aarch64 (qemu-user-static) to run the resulting binary.

. "$BINATE_DIR/scripts/lib/build-compilers.sh"

QEMU_AARCH64="${QEMU_AARCH64:-}"
if [ -z "$QEMU_AARCH64" ]; then
    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        QEMU_AARCH64=qemu-aarch64-static
    elif command -v qemu-aarch64 >/dev/null 2>&1; then
        QEMU_AARCH64=qemu-aarch64
    fi
fi

# host_is_aarch64 returns 0 (true) if running on aarch64.
host_is_aarch64() {
    case "$(uname -m)" in
        arm64|aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

runner_setup() {
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_native_aa64_linux requires clang" >&2
        exit 2
    fi
    # Sanity probe: clang must be able to target aarch64-linux-gnu.
    # Catches a missing cross-toolchain early instead of failing per-test.
    if ! echo 'int main(void){return 0;}' | clang -target aarch64-linux-gnu -x c -c - -o /tmp/_bn_aa64l_probe.o 2>/dev/null; then
        echo "error: clang cannot target aarch64-linux-gnu" >&2
        echo "  Linux:  apt install gcc-aarch64-linux-gnu  (or run on an aarch64 host)" >&2
        echo "  macOS:  a Linux aarch64 sysroot is required (Apple clang lacks it)" >&2
        rm -f /tmp/_bn_aa64l_probe.o
        exit 2
    fi
    rm -f /tmp/_bn_aa64l_probe.o
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
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root" --target aarch64-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" \
        --backend native --target aarch64-linux --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" \
        $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # Host vs cross: an aarch64 host runs the binary natively; anything else
        # routes through qemu-aarch64 user-mode emulation.
        if host_is_aarch64; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 10 "$tmpbin" 2>&1 || true
            elif command -v gtimeout >/dev/null 2>&1; then
                gtimeout 10 "$tmpbin" 2>&1 || true
            else
                "$tmpbin" 2>&1 || true
            fi
        elif [ -n "$QEMU_AARCH64" ]; then
            # qemu-user shares the host filesystem, but the produced binaries are
            # dynamically linked and their interpreter (/lib/ld-linux-aarch64.so.1)
            # lives in the cross sysroot, not the host's /lib.  QEMU_LD_PREFIX
            # points qemu at that sysroot; gcc-aarch64-linux-gnu installs it under
            # /usr/aarch64-linux-gnu.  Mirrors the arm32_linux runner.
            QEMU_LD_PREFIX="${QEMU_LD_PREFIX:-/usr/aarch64-linux-gnu}"
            export QEMU_LD_PREFIX
            if command -v timeout >/dev/null 2>&1; then
                timeout 10 "$QEMU_AARCH64" "$tmpbin" 2>&1 || true
            elif command -v gtimeout >/dev/null 2>&1; then
                gtimeout 10 "$QEMU_AARCH64" "$tmpbin" 2>&1 || true
            else
                "$QEMU_AARCH64" "$tmpbin" 2>&1 || true
            fi
        else
            echo "RUN_SKIPPED: no qemu-aarch64 and host is not aarch64"
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
