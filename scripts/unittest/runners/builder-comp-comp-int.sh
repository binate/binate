#!/bin/sh
# Runner: builder-comp-comp-int — Gen1-compiled bytecode VM runs --test natively.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# Band-aid for the bni VM host-stack-overflow MAJOR (see
# claude-todo.md + plan-bni-heap-frames.md): bni's extern-callback
# path consumes ~3 KB of host stack per cross-VM round-trip, so
# deeply-recursive interpreted code (type-checker, IR-gen) blows
# the 8 MiB default stack.  Bump to as much as the host allows.
# Remove once the heap-frames refactor lands.
ulimit -s unlimited 2>/dev/null || ulimit -s 65520 2>/dev/null || true

runner_setup() { build_gen1; build_interp "$GEN1_COMPILER"; }

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
