#!/bin/sh
# Runner: boot-comp-int2-int2 — Compiled bni2 interprets cmd/bni2, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_int2_boot_comp; }

runner_test() {
    pkg="$1"
    "$COMPILED_INT2" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni2" -- --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
