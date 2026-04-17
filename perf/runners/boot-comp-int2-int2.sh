#!/bin/sh
# Runner: boot-comp-int2-int2 — compiled bni2 interprets cmd/bni2, which interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_int2_boot_comp; }

runner_run() {
    bn="$1"
    "$COMPILED_INT2" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni2" -- -root "$BINATE_DIR" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
