#!/bin/sh
# Runner: boot-comp-comp-comp — Gen2 compiler compiles and runs tests.

GEN1_COMPILER="/tmp/binate_gen1_compiler_$$"
GEN2_COMPILER="/tmp/binate_gen2_compiler_$$"

runner_setup() {
    echo "Building gen1 compiler..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN1_COMPILER" ]; then
        echo "ERROR: Failed to build gen1 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen1 compiler ready: $GEN1_COMPILER"

    echo "Building gen2 compiler..."
    build_out=$("$GEN1_COMPILER" --root "$BINATE_DIR" -o "$GEN2_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN2_COMPILER" ]; then
        echo "ERROR: Failed to build gen2 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen2 compiler ready: $GEN2_COMPILER"
}

runner_test() {
    pkg="$1"
    testbin=$("$GEN2_COMPILER" --test --root "$BINATE_DIR" "$pkg" 2>&1)
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
    rm -f "$GEN1_COMPILER" "$GEN2_COMPILER"
}
