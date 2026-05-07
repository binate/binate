#!/bin/sh
# Runner: boot-comp_native_aa64 — bootstrap interprets bnc with
# -backend=native (aarch64 Mach-O via pkg/native), then runs the binary.
# macOS/Apple Silicon only; mirrors conformance/runners/boot-comp_native_aa64.sh.

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" \
        "$BINATE_DIR/cmd/bnc" -- --root "$(dirname "$bn")" \
        --build-dir "$bdir" -backend native -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    # The skeleton native backend produces incorrect code for some
    # features (e.g. function parameters), which can yield infinite
    # loops.  Cap wall-clock via timeout(1) so the sweep doesn't wedge.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$tmpbin" 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 3 "$tmpbin" 2>&1
    else
        "$tmpbin" 2>&1
    fi
}
