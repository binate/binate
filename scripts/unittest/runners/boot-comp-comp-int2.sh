#!/bin/sh
# Runner: boot-comp-comp-int2 — Gen1-compiled bytecode VM runs --test.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_int2 "$GEN1_COMPILER"; }

runner_test() {
    pkg="$1"
    "$COMPILED_INT2" --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
