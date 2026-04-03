#!/bin/sh
# Runner: boot-int — Bootstrap interprets bni, which runs -test.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    (cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- --test -root "$BINATE_DIR" "$pkg")
}

runner_cleanup() {
    : # nothing to clean up
}
