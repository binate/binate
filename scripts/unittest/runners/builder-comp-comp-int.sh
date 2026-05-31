#!/bin/sh
# Runner: builder-comp-comp-int — Gen1-compiled bytecode VM runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" --test --skip "$SKIP_FILTER" \
            -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$pkg"
    else
        "$COMPILED_INTERP" --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
