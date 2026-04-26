#!/bin/sh
# Runner: boot-comp_native_aa64 — bootstrap interprets bnc, which
# compiles tests via the native AArch64 Mach-O backend.
#
# Mode-name convention: stages within one compile chain are joined
# with `_` (the chain here is comp_native_aa64 — bnc with the native
# aarch64 backend); separate stages join with `-`.

runner_setup() {
    : # nothing to build
}

runner_test() {
    pkg="$1"
    testbin=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --test --backend native --root "$BINATE_DIR" "$pkg" 2>&1)
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
