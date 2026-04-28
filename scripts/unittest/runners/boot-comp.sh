#!/bin/sh
# Runner: boot-comp — Bootstrap interprets bnc, which compiles tests to a binary.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    # bnc --test compiles and prints the test binary path. Per-pkg
    # build dir keeps intermediates (and the binary, which lives
    # under <build-dir> in --build-dir mode) isolated from concurrent
    # test runs.
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    testbin=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --root "$BINATE_DIR" --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() {
    : # nothing to clean up
}
