#!/bin/sh
# Runner: boot-comp-native-aa64 — boot interprets cmd/bnc with -backend=native,
# compiling test.bn via pkg/native (aarch64 Mach-O). macOS/Apple Silicon only.

runner_setup() {
    : # nothing to build
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_${name}_$$"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$compile_root" -backend native $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        # The skeleton produces incorrect code for features it doesn't
        # handle (e.g. function parameters), which can yield infinite
        # loops. Cap wall-clock via timeout(1) so the sweep doesn't wedge.
        if command -v timeout >/dev/null 2>&1; then
            timeout 3 "$tmpbin" 2>&1 || true
        elif command -v gtimeout >/dev/null 2>&1; then
            gtimeout 3 "$tmpbin" 2>&1 || true
        else
            "$tmpbin" 2>&1 || true
        fi
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
}

runner_cleanup() {
    : # nothing to clean up
}
