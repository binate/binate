#!/bin/sh
# Runner: boot-comp-int — Compiled bni2 (bytecode VM) runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    "$COMPILED_INTERP" --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
