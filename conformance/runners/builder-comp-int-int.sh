#!/bin/sh
# Runner: builder-comp-int-int — compiled bni interprets cmd/bni, which interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_exec() {
    bn="$1"; root="$2"
    # The INNER bni (after `--`) resolves the test program's imports, so it
    # needs the core + stdlib search roots — not just $root:$BINATE_DIR.
    # Without ifaces/core + impls/core/libc a multi-package test that pulls
    # in pkg/builtins/rt fails with `package "pkg/builtins/rt" not found`
    # (only under int-int — the single-int runner already passes the full
    # set). Mirror builder-comp-int.sh's root list, with $root prepended.
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- -I "$root:$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$root:$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
