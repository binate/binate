#!/bin/sh
# Runner: builder-comp_native_aa64-comp_native_aa64 — Bootstrap builds bnc
# with --backend native (cmd/bnc's main module emitted via the native
# aarch64 path; deps still go through LLVM as in compileMainNative's
# hybrid).  That native bnc binary then compiles each conformance test
# with --backend native.  macOS/Apple Silicon only.
#
# Why this exists: the older `builder-comp_native_aa64` runner invoked
# `go run bootstrap → bnc --backend native` per test, paying the
# bootstrap-interpretation tax on every compile.  Native EmitObject
# under bootstrap interp is the dominant cost — running it once for
# bnc itself rather than once per test amortises that cost.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_bnc_native_aa64; }

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
    compile_out=$("$BNC_NATIVE" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" --build-dir "$bdir" -backend native $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # Cap wall-clock via timeout(1) so a runaway test (e.g. a
        # codegen bug that yields an infinite loop) doesn't wedge the
        # sweep.  Inherited from the older builder-comp_native_aa64
        # runner.
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 3 "$tmpbin" 2>&1 || true
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
