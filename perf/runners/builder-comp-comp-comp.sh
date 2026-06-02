#!/bin/sh
# Runner: builder-comp-comp-comp — gen2 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    # Full stdlib search paths — see builder-comp.sh for why the test
    # dir alone can't link println(int) → bootstrap.formatInt64.
    out=$("$GEN2_COMPILER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1)
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
