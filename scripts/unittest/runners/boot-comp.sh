#!/bin/sh
# Runner: boot-comp — Bootstrap interprets bnc, which compiles tests to a binary.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    # bnc --test compiles and prints the test binary path
    testbin=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --root "$BINATE_DIR" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        return 1
    fi
    "$testbin" 2>&1
    rc=$?
    rm -f "$testbin"
    return $rc
}

runner_cleanup() {
    : # nothing to clean up
}
