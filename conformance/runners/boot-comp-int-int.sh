#!/bin/sh
# Runner: boot-comp-int-int — compiled interpreter interprets cmd/bni, which interprets test.bn.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_exec() {
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -root "$root" -add-root "$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bni" -- -root "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
