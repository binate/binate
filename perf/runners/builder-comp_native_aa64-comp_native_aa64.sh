#!/bin/sh
# Runner: builder-comp_native_aa64-comp_native_aa64 — bootstrap builds bnc
# with --backend native once, then that native bnc binary compiles each
# perf test with --backend native.  macOS/Apple Silicon only.  Mirrors
# conformance/runners/builder-comp_native_aa64-comp_native_aa64.sh.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_bnc_native_aa64; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    # Full stdlib search paths — see builder-comp.sh for why the test
    # dir alone can't link a test's stdlib/builtins imports.
    out=$("$BNC_NATIVE" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$bdir" \
        -backend native -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    # Cap wall-clock via timeout(1) so a runaway test (e.g. a codegen
    # bug that yields an infinite loop) doesn't wedge the sweep.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$tmpbin" 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 3 "$tmpbin" 2>&1
    else
        "$tmpbin" 2>&1
    fi
}

runner_cleanup() { cleanup_compilers; }
