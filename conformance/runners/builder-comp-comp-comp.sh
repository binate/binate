#!/bin/sh
# Runner: builder-comp-comp-comp — gen2 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_exec() {
    bn="$1"; root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_g2_${name}_$$"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then compile_root="$root"; fi
    compile_out=$("$GEN2_COMPILER" -I "$compile_root" -L "$compile_root" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR (exit $?): $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
