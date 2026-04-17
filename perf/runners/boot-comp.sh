#!/bin/sh
# Runner: boot-comp — bootstrap interprets bnc to compile, then runs binary.

runner_compile() {
    bn="$1"
    tmpbin="$2"
    cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" \
        "$BINATE_DIR/cmd/bnc" -- --root "$(dirname "$bn")" \
        -o "$tmpbin" "$bn" 2>&1
}

runner_run() {
    tmpbin="$2"
    "$tmpbin" 2>&1
}
