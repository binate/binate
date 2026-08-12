#!/bin/sh
# Runner: builder-comp_native_x64_darwin-comp_native_x64_darwin —
# current-tree cmd/bnc (built via the LLVM path → GEN1) compiles each
# test package with `--test --backend native --target x86_64-darwin`,
# producing an x86-64 Mach-O test binary that runs under Rosetta on
# Apple Silicon (natively on Intel).
#
# macOS sibling of the (not-yet-present) ELF unit runner; the point is
# to exercise the amd64 native backend's test output end-to-end on a
# stock Apple-Silicon dev machine.  The amd64 backend only lowers a
# subset of ops today, so most packages fail to compile — that's the
# measurable starting point, shrinking as op-coverage lands.
#
# Like the ELF conformance runner, this drives GEN1 (LLVM-built bnc)
# rather than a pre-built native bnc: the native backend can't yet
# self-compile a working bnc.  Local-only by design — not in any CI
# modeset (see plan-backend-objformat-decoupling.md: x64+Mach-O is the
# local dev axis; CI covers arch+format via native_aa64 + native_x64).
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
        echo "  (Mach-O test binaries don't run on Linux)" >&2
        exit 2
    fi
    if ! command -v clang >/dev/null 2>&1; then
        echo "error: builder-comp_native_x64_darwin requires clang" >&2
        exit 2
    fi
    build_gen1
}

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    testbin=$("$GEN1_COMPILER" --test --backend native --target x86_64-darwin \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target x86_64-darwin)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # compile/link error output
        rm -rf "$bdir"
        return 1
    fi
    # Direct exec — Rosetta runs the x86-64 Mach-O transparently.
    "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
