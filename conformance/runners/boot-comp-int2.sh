#!/bin/sh
# Runner: boot-comp-int2 — boot-comp compiles cmd/bni2 → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

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

runner_exec() {
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INT2" -root "$root" -add-root "$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$COMPILED_INT2" -root "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() {
    rm -f "$COMPILED_INT2"
}
