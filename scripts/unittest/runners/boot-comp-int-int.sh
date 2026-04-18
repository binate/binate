#!/bin/sh
# Runner: boot-comp-int-int — Compiled bni2 interprets cmd/bni2, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni2" -- --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
