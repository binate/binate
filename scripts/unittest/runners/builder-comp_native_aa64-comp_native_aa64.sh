#!/bin/sh
# Runner: builder-comp_native_aa64-comp_native_aa64 — current-tree
# cmd/bnc (compiled via the LLVM path → GEN1) is then re-compiled
# with its own native AArch64 backend → BNC_NATIVE; that BNC_NATIVE
# binary compiles each test package with --backend native and the
# test binary runs natively.  build_bnc_native_aa64 calls build_gen1
# up-front so the "first comp" is always current-tree cmd/bnc — the
# BUILDER (bnc-X.Y.Z or bootstrap) only ever drives the gen1 build,
# never directly emits native code.
#
# Mode-name convention: stages within one compile chain are joined
# with `_` (chains here are comp_native_aa64 — bnc built with the
# native backend, then comp_native_aa64 — that bnc compiling tests
# with the native backend); separate stages join with `-`.
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

runner_setup() { build_bnc_native_aa64; }

runner_test() {
    pkg="$1"
    bdir="$(mktemp -d /tmp/binate_build_XXXXXX)"
    testbin=$("$BNC_NATIVE" --test --backend native -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$bdir" "$pkg" 2>&1)
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
