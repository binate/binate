#!/bin/sh
# Runner: builder-comp-int-int — Compiled bni interprets cmd/bni, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- \
            --test --skip "$SKIP_FILTER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$pkg"
    else
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- \
            --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
