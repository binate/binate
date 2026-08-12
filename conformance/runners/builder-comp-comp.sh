#!/bin/sh
# Runner: builder-comp-comp — gen1 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_exec() {
    bn="$1"; root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="$(mktemp "${TMPDIR:-/tmp}/binate_conform_cc_${name}_XXXXXX")"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then compile_root="$root"; fi
    compile_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$compile_root")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$compile_root")" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR (exit $?): $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() { cleanup_compilers; }
