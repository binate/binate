#!/bin/sh
# Runner: boot-comp-comp — gen1 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    src_dir="$(dirname "$bn")"
    out=$("$GEN1_COMPILER" -I "$src_dir" -L "$src_dir" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    "$tmpbin" 2>&1
}

runner_cleanup() { cleanup_compilers; }
