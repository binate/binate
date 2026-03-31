#!/bin/sh
# Runner: bootstrap interpreter (Go) directly interprets .bn files.

runner_setup() {
    : # nothing to build
}

runner_exec() {
    bn="$1"
    root="$2"
    if [ -n "$root" ]; then
        (cd "$BOOTSTRAP_DIR" && go run . -root "$root" -add-root "$BINATE_DIR" "$bn" 2>&1) || true
    else
        (cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$bn" 2>&1) || true
    fi
}

runner_cleanup() {
    : # nothing to clean up
}
