#!/bin/sh
# Runner: self-compiled interpreter binary runs .bn files.
# The interpreter (main.bn) is compiled once during setup, then reused for all tests.

COMPILED_INTERP="/tmp/binate_compiled_interp_$$"

runner_setup() {
    echo "Building compiled interpreter..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/compile.bn" -- --root "$BINATE_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/main.bn" 2>&1)
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
        "$COMPILED_INTERP" -root "$root" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" "$bn" 2>&1 || true
    fi
}

runner_cleanup() {
    rm -f "$COMPILED_INTERP"
}
