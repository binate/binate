#!/bin/sh
# Runner: builder-comp-int-int — compiled bni interprets cmd/bni, which interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_run() {
    bn="$1"
    # Full stdlib search paths on BOTH the outer (compiled-bni compiling
    # cmd/bni) and inner (cmd/bni interpreting the test) invocations —
    # bare $BINATE_DIR misses the ifaces/impls split (pkg-layout
    # migration), so cmd/bni itself failed to resolve its stdlib imports.
    ip="$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib"
    lp="$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common"
    "$COMPILED_INTERP" -I "$ip" -L "$lp" "$BINATE_DIR/cmd/bni" -- -I "$ip" -L "$lp" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
