#!/bin/sh
# Runner: boot — Go bootstrap interprets the test directly.

runner_run() {
    bn="$1"
    cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$bn" 2>&1
}
