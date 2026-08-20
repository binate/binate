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
        "$COMPILED_INTERP" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-dir "$BINATE_DIR/cmd/bni" -- ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$root")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$root")" -main-file "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-dir "$BINATE_DIR/cmd/bni" -- ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-file "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
