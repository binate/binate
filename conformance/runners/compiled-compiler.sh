#!/bin/sh
# Runner: self-compiled compiler binary compiles test to native binary,
# then runs the binary.
# The compiler (compile.bn) is compiled once during setup, then reused for all tests.

COMPILED_COMPILER="/tmp/binate_compiled_compiler_$$"

runner_setup() {
    echo "Building compiled compiler..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/compile.bn" -- --root "$BINATE_DIR" -o "$COMPILED_COMPILER" "$BINATE_DIR/compile.bn" 2>&1)
    if [ ! -x "$COMPILED_COMPILER" ]; then
        echo "ERROR: Failed to build compiled compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled compiler ready: $COMPILED_COMPILER"
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_cc_${name}_$$"
    compile_root=""
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    if [ -n "$compile_root" ]; then
        compile_out=$("$COMPILED_COMPILER" --root "$compile_root" -o "$tmpbin" "$bn" 2>&1) || true
    else
        compile_out=$("$COMPILED_COMPILER" -o "$tmpbin" "$bn" 2>&1) || true
    fi
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
}

runner_cleanup() {
    rm -f "$COMPILED_COMPILER"
}
