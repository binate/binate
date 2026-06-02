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
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    # Full stdlib search paths (matching the conformance/unit runners):
    # the bare $BINATE_DIR resolves pkg/bootstrap (println(int) lowers to
    # bootstrap.formatInt64) + pkg/binate/*; the ifaces/impls entries
    # resolve the split stdlib.  -I/-L of the test dir alone could not
    # link these, so every int-printing perf test failed.
    out=$("$GEN1_COMPILER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
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
