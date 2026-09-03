#!/bin/sh
# Runner: builder-comp-comp — gen2 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    # Full stdlib search paths — see builder-comp.sh for why the test
    # dir alone can't link a test's stdlib/builtins imports.
    out=$("$GEN2_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1)
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
