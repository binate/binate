#!/bin/sh
# Runner: boot-comp-int — Compiled bni runs --test natively.

COMPILED_INTERP="/tmp/binate_compiled_interp_$$"

runner_setup() {
    echo "Building compiled interpreter..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

runner_test() {
    pkg="$1"
    "$COMPILED_INTERP" --test -root "$BINATE_DIR" "$pkg"
}

runner_cleanup() {
    rm -f "$COMPILED_INTERP"
}
