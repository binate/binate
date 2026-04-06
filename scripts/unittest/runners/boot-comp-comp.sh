#!/bin/sh
# Runner: boot-comp-comp — Gen1 compiler compiles and runs tests.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_test() {
    pkg="$1"
    testbin=$("$GEN1_COMPILER" --test --root "$BINATE_DIR" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then echo "$testbin"; return 1; fi
    "$testbin" 2>&1; rc=$?; rm -f "$testbin"; return $rc
}

runner_cleanup() { cleanup_compilers; }
