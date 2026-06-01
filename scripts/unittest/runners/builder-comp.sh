#!/bin/sh
# Runner: builder-comp — current-tree cmd/bnc compiles each test package.
# The BUILDER (resolved BUILDER_VERSION binary) is used to compile
# current cmd/bnc once during runner_setup → GEN1_COMPILER; every
# per-test compile then goes through GEN1, so the "comp" link is
# always current-tree cmd/bnc regardless of which builder is pinned.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_gen1; }

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    testbin=$("$GEN1_COMPILER" --test -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common" \
        --build-dir "$bdir" "$pkg" 2>&1)
    if [ ! -x "$testbin" ]; then
        echo "$testbin"  # error output
        rm -rf "$bdir"
        return 1
    fi
    "$testbin" 2>&1
    rc=$?
    rm -rf "$bdir"
    return $rc
}

runner_cleanup() { cleanup_compilers; }
