#!/bin/sh
# Runner: builder-comp — current-tree cmd/bnc (compiled via the
# BUILDER during runner_setup → GEN1_COMPILER) compiles each perf
# test to a native binary.  Matches the unit-test / conformance
# builder-comp runners: the BUILDER's only job is to compile cmd/bnc
# once; per-test compiles all go through GEN1, so we measure
# current-tree cmd/bnc throughput rather than the BUILDER's.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    # Full stdlib search paths (matching the conformance/unit runners):
    # the bare $BINATE_DIR resolves pkg/binate/*; the
    # ifaces/impls entries resolve the split stdlib.  -I/-L of the test
    # dir alone could not link a test's stdlib/builtins imports (e.g.
    # pkg/builtins/testing → pkg/builtins/lang), so every perf test that
    # produces output failed.
    out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
        --build-dir "$bdir" -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    "$tmpbin" 2>&1
}

runner_cleanup() { cleanup_compilers; }
