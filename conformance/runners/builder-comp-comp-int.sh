#!/bin/sh
# Runner: builder-comp-comp-int — gen2 compiler compiles cmd/bni → binary, binary interprets test.bn via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; build_gen2; build_interp "$GEN2_COMPILER"; }

runner_exec() {
    _rc=0
    bn="$1"; root="$2"
    if [ -n "$root" ]; then
        "$COMPILED_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$root")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$root")" -main-file "$bn" 2>&1; _rc=$?
    else
        "$COMPILED_INTERP" ${CONF_CHECK_NIL:+--check-nil} -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" -main-file "$bn" 2>&1; _rc=$?
    fi
    return $_rc
}

runner_cleanup() { cleanup_compilers; }
