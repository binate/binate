#!/bin/sh
# Runner: boot-comp-int — boot-comp compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_run() {
    bn="$1"
    "$COMPILED_INTERP" -I "$BINATE_DIR" -L "$BINATE_DIR" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
