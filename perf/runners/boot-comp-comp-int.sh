#!/bin/sh
# Runner: boot-comp-comp-int — gen1 compiler compiles cmd/bni → binary, binary interprets test.bn.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_run() {
    bn="$1"
    "$COMPILED_INTERP" -root "$BINATE_DIR" "$bn" 2>&1
}

runner_cleanup() { cleanup_compilers; }
