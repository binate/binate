#!/bin/sh
# Shared helpers for building gen1/gen2 compilers and compiled interpreters.
# Source this from runner scripts.

# Build gen1 compiler (boot-comp compiles cmd/bnc → gen1 binary)
# Sets GEN1_COMPILER to the path.
build_gen1() {
    GEN1_COMPILER="/tmp/binate_gen1_compiler_$$"
    echo "Building gen1 compiler..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN1_COMPILER" ]; then
        echo "ERROR: Failed to build gen1 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen1 compiler ready: $GEN1_COMPILER"
}

# Build gen2 compiler (gen1 compiles cmd/bnc → gen2 binary)
# Requires GEN1_COMPILER to be set (call build_gen1 first).
# Sets GEN2_COMPILER to the path.
build_gen2() {
    GEN2_COMPILER="/tmp/binate_gen2_compiler_$$"
    echo "Building gen2 compiler..."
    build_out=$("$GEN1_COMPILER" --root "$BINATE_DIR" -o "$GEN2_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN2_COMPILER" ]; then
        echo "ERROR: Failed to build gen2 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen2 compiler ready: $GEN2_COMPILER"
}

# Build compiled interpreter using a given compiler.
# $1 = compiler binary path
# Sets COMPILED_INTERP to the path.
build_interp() {
    local compiler="$1"
    COMPILED_INTERP="/tmp/binate_compiled_interp_$$"
    echo "Building compiled interpreter..."
    build_out=$("$compiler" --root "$BINATE_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

# Build compiled interpreter using bootstrap→bnc (boot-comp).
build_interp_boot_comp() {
    COMPILED_INTERP="/tmp/binate_compiled_interp_$$"
    echo "Building compiled interpreter..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

# Cleanup helper — removes all temp binaries.
cleanup_compilers() {
    rm -f "$GEN1_COMPILER" "$GEN2_COMPILER" "$COMPILED_INTERP"
}
