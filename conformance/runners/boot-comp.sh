#!/bin/sh
# Runner: boot-comp — the BUILDER_VERSION binary interprets cmd/bnc,
# which compiles test.bn to native.  (BUILDER_VERSION currently names
# the bootstrap interpreter.)

runner_setup() {
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
    BOOT_BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
}

runner_exec() {
    bn="$1"
    root="$2"
    name="$(basename "$bn" .bn)"
    tmpbin="/tmp/binate_conform_${name}_$$"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    compile_root="$BINATE_DIR"
    if [ -n "$root" ]; then
        compile_root="$root"
    fi
    compile_out=$("$BOOT_BUILDER" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- -I "$compile_root:$BOOT_BUILDER_LIB" -L "$compile_root:$BOOT_BUILDER_LIB" --build-dir "$bdir" $BINATE_FLAGS -o "$tmpbin" "$bn" 2>&1) || true
    if [ -x "$tmpbin" ]; then
        "$tmpbin" 2>&1 || true
    else
        echo "COMPILE_ERROR: $compile_out"
    fi
    rm -f "$tmpbin"
    rm -rf "$bdir"
}

runner_cleanup() {
    : # nothing to clean up
}
