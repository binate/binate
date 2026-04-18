#!/bin/sh
# Runner: boot-comp-comp-int2 — gen1 compiler compiles cmd/bni2 → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_int2 "$GEN1_COMPILER"; }

runner_run() {
    bn="$1"
    "$COMPILED_INT2" -root "$BINATE_DIR" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
