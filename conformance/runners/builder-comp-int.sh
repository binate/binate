#!/bin/sh
# Runner: builder-comp-int — builder-comp compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_interp_boot_comp; }

runner_exec() {
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$root")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$root")" -main-file "$bn" 2>&1 || true
    else
        "$COMPILED_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-file "$bn" 2>&1 || true
    fi
}

runner_cleanup() { cleanup_compilers; }
