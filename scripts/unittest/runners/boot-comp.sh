#!/bin/sh
# Runner: boot-comp — Bootstrap interprets bnc, which compiles and runs tests.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    (cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --root "$BINATE_DIR" "$pkg")
}

runner_cleanup() {
    : # nothing to clean up
}
