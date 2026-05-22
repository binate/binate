#!/bin/sh
# Runner: builder-comp — bootstrap interprets bnc to compile, then runs binary.

runner_compile() {
    bn="$1"
    tmpbin="$2"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    src_dir="$(dirname "$bn")"
    out=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" \
        "$BINATE_DIR/cmd/bnc" -- -I "$src_dir" -L "$src_dir" \
        --build-dir "$bdir" -o "$tmpbin" "$bn" 2>&1)
    rc=$?
    rm -rf "$bdir"
    [ -n "$out" ] && echo "$out"
    return $rc
}

runner_run() {
    tmpbin="$2"
    "$tmpbin" 2>&1
}
