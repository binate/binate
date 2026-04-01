#!/bin/sh
# Runner: boot-comp-comp-comp — boot-comp builds gen1, gen1 compiles cmd/bnc → gen2, gen2 compiles test.bn.

GEN1_COMPILER="/tmp/binate_gen1_$$"
GEN2_COMPILER="/tmp/binate_gen2_$$"

runner_setup() {
    echo "Building gen1 compiler (bootstrap → compile.bn)..."
    build_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN1_COMPILER" ]; then
        echo "ERROR: Failed to build gen1 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "gen1 ready: $GEN1_COMPILER"

    echo "Building gen2 compiler (gen1 → compile.bn)..."
    build_out=$("$GEN1_COMPILER" --root "$BINATE_DIR" -o "$GEN2_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN2_COMPILER" ]; then
        echo "ERROR: Failed to build gen2 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "gen2 ready: $GEN2_COMPILER"
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_g2_${name}_$$"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$("$GEN2_COMPILER" --root "$compile_root" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1)
    compile_rc=$?
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR (exit $compile_rc): $compile_out"
    fi
    rm -f "$tmpbin"
}

runner_cleanup() {
    rm -f "$GEN1_COMPILER" "$GEN2_COMPILER"
}
