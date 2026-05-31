#!/bin/sh
# Runner: builder-comp — current-tree cmd/bnc (compiled via the BUILDER
# during runner_setup → GEN1_COMPILER) compiles each test.bn to a
# native binary.  The "comp" link is always current-tree cmd/bnc,
# regardless of whether BUILDER_VERSION names bootstrap-* or bnc-*.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_${name}_$$"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$("$GEN1_COMPILER" -I "$compile_root:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$compile_root:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/stdlib/common" \
        --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
