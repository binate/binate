#!/bin/sh
# Runner: builder-comp-int — builder-comp compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_run() {
    bn="$1"
    # Full stdlib search paths — bare $BINATE_DIR misses the
    # ifaces/impls split, so even noop tests would fail to resolve
    # stdlib packages.
    "$COMPILED_INTERP" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-file "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
