#!/bin/sh
# Runner: boot — Go bootstrap interpreter runs -test directly.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    (cd "$BOOTSTRAP_DIR" && go run . -test -root "$BINATE_DIR" "$pkg")
}

runner_cleanup() {
    : # nothing to clean up
}
