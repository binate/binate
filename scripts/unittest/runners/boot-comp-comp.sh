#!/bin/sh
# Runner: boot-comp-comp — Self-compiled compiler (gen1) compiles and runs tests.

GEN1_COMPILER="/tmp/binate_gen1_compiler_$$"

runner_setup() {
    echo "Building gen1 compiler..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN1_COMPILER" ]; then
        echo "ERROR: Failed to build gen1 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen1 compiler ready: $GEN1_COMPILER"
}

runner_test() {
    pkg="$1"
    testbin=$("$GEN1_COMPILER" --test --root "$BINATE_DIR" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"
        return 1
    fi
    "$testbin" 2>&1
    rc=$?
    rm -f "$testbin"
    return $rc
}

runner_cleanup() {
    rm -f "$GEN1_COMPILER"
}
