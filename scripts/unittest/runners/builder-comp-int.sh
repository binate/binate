#!/bin/sh
# Runner: builder-comp-int — Compiled bni (bytecode VM) runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# Band-aid for the bni VM host-stack-overflow MAJOR (see
# claude-todo.md + plan-bni-heap-frames.md): bni's extern-callback
# path consumes ~3 KB of host stack per cross-VM round-trip, so
# deeply-recursive interpreted code (type-checker, IR-gen) blows
# the 8 MiB default stack.  Cap at 64 MiB — gives ~8× headroom so
# most tests pass while preserving fast-crash behavior when an
# algorithm is pathologically deep.  An earlier attempt at
# `ulimit -s unlimited` on Linux turned crashes into multi-minute
# hangs (the type-checker's recursion is O(depth) and never
# terminated with effectively-infinite headroom), which is worse
# for CI than the original crash.  Remove this entire bandaid
# once the heap-frames refactor lands.
ulimit -s 65520 2>/dev/null || true

runner_setup() { build_interp_boot_comp; }

runner_test() {
    pkg="$1"
    if [ -n "$SKIP_FILTER" ]; then
        "$COMPILED_INTERP" --test --skip "$SKIP_FILTER" \
            -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$pkg"
    else
        "$COMPILED_INTERP" --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" "$pkg"
    fi
}

runner_cleanup() { cleanup_compilers; }
