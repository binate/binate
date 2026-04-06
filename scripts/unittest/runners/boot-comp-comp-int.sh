#!/bin/sh
# Runner: boot-comp-comp-int — Gen1-compiled interpreter runs --test.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_test() {
    pkg="$1"
    "$COMPILED_INTERP" --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
