#!/bin/sh
# Runner: boot-comp-int-int — Compiled interpreter interprets cmd/bni, which runs --test.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() { cleanup_compilers; }
