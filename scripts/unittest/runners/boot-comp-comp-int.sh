#!/bin/sh
# Runner: boot-comp-comp-int — Gen1-compiled bytecode VM runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" --test --skip "$SKIP_FILTER" \
            -I "$BINATE_DIR" -L "$BINATE_DIR" "$pkg"
    else
        "$COMPILED_INTERP" --test -I "$BINATE_DIR" -L "$BINATE_DIR" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
