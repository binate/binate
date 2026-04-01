#!/bin/sh
# Runner: boot-comp-int-int — boot-comp compiles cmd/bni → binary, binary interprets cmd/bni, which interprets test.bn.

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

runner_exec() {
    bn="$1"
    root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -root "$root" -add-root "$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -root "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() {
    rm -f "$COMPILED_INTERP"
}
