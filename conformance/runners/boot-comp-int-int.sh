#!/bin/sh
# Runner: boot-comp-int-int — compiled bni interprets cmd/bni, which interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_exec() {
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" -I "$BINATE_DIR" -L "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -I "$root:$BINATE_DIR" -L "$root:$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -I "$BINATE_DIR" -L "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -I "$BINATE_DIR" -L "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
