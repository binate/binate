#!/bin/sh
# Runner: self-hosted interpreter (main.bn) interpreted by the bootstrap.

runner_setup() {
    : # nothing to build
}

runner_exec() {
    bn="$1"
    root="$2"
    if [ -n "$root" ]; then
        (cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/main.bn" -- -root "$root" "$bn" 2>&1) || true
    else
        (cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/main.bn" -- "$bn" 2>&1) || true
    fi
}

runner_cleanup() {
    : # nothing to clean up
}
