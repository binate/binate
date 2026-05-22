#!/bin/sh
# Runner: builder-comp-int — builder-comp compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_exec() {
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" -I "$root:$BINATE_DIR" -L "$root:$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -I "$BINATE_DIR" -L "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
