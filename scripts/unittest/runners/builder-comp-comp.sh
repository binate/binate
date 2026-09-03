#!/bin/sh
# Runner: builder-comp-comp — Gen2 compiler compiles and runs tests.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; }

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d "${TMPDIR:-/tmp}/binate_build_XXXXXX")"
    testbin=$("$GEN2_COMPILER" --test -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then echo "$testbin"; rm -rf "$bdir"; return 1; fi
    "$testbin" 2>&1; rc=$?; rm -rf "$bdir"; return $rc
}

runner_cleanup() { cleanup_compilers; }
