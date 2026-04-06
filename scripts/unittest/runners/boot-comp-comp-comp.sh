#!/bin/sh
# Runner: boot-comp-comp-comp — Gen2 compiler compiles and runs tests.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_test() {
    pkg="$1"
    testbin=$("$GEN2_COMPILER" --test --root "$BINATE_DIR" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then echo "$testbin"; return 1; fi
    "$testbin" 2>&1; rc=$?; rm -f "$testbin"; return $rc
}

runner_cleanup() { cleanup_compilers; }
