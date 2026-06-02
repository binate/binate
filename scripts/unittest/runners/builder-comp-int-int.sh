#!/bin/sh
# Runner: builder-comp-int-int — Compiled bni interprets cmd/bni, which runs --test via bytecode VM.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# Band-aid for the bni VM host-stack-overflow MAJOR (see
# claude-todo.md + plan-bni-heap-frames.md): bni's extern-callback
# path consumes ~3 KB of host stack per cross-VM round-trip, so
# deeply-recursive interpreted code (type-checker, IR-gen) blows
# the 8 MiB default stack.  Double interpretation here makes the
# growth twice as bad.  Bump to as much as the host allows.  Remove
# once the heap-frames refactor lands.
ulimit -s unlimited 2>/dev/null || ulimit -s 65520 2>/dev/null || true

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- \
            --test --skip "$SKIP_FILTER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$pkg"
    else
        "$COMPILED_INTERP" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$BINATE_DIR/cmd/bni" -- \
            --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
