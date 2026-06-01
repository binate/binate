#!/bin/sh
# Runner: builder-comp-comp-comp — Gen2 compiler compiles and runs tests.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    testbin=$("$GEN2_COMPILER" --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then echo "$testbin"; rm -rf "$bdir"; return 1; fi
    "$testbin" 2>&1; rc=$?; rm -rf "$bdir"; return $rc
}

runner_cleanup() { cleanup_compilers; }
