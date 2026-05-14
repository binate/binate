#!/bin/sh
# Runner: boot-comp-int-int — Compiled bni interprets cmd/bni, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- \
            --test --skip "$SKIP_FILTER" -root "$BINATE_DIR" "$pkg"
    else
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- \
            --test -root "$BINATE_DIR" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
