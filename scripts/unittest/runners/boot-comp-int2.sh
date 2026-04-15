#!/bin/sh
# Runner: boot-comp-int2 — Compiled bni2 (bytecode VM) runs --test natively.
# NOTE: cmd/bni2 does not support --test yet. This runner is a placeholder.

COMPILED_INT2=""

runner_setup() {
    COMPILED_INT2="/tmp/binate_compiled_int2_$$"
    echo "Building compiled bytecode interpreter..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$COMPILED_INT2" "$BINATE_DIR/cmd/bni2" 2>&1)
    if [ ! -x "$COMPILED_INT2" ]; then
        echo "ERROR: Failed to build bytecode interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Bytecode interpreter ready: $COMPILED_INT2"
}

runner_test() {
    pkg="$1"
    "$COMPILED_INT2" --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() {
    rm -f "$COMPILED_INT2"
}
