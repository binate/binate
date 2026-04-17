#!/bin/sh
# Runner: boot-comp-comp-comp — gen2 compiler compiles test.bn to native.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_compile() {
    bn="$1"
    tmpbin="$2"
    "$GEN2_COMPILER" --root "$(dirname "$bn")" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1
}

runner_run() {
    tmpbin="$2"
    "$tmpbin" 2>&1
}

runner_cleanup() { cleanup_compilers; }
