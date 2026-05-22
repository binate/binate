#!/bin/sh
# Runner: builder-comp-comp-int — gen1 compiler compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_run() {
    bn="$1"
    "$COMPILED_INTERP" -I "$BINATE_DIR" -L "$BINATE_DIR" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
