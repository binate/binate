#!/bin/sh
# Runner: boot-comp_native_aa64-comp_native_aa64 — Bootstrap builds bnc
# with --backend native (cmd/bnc's main module emitted via the native
# aarch64 path; bnc's own dep modules still go through LLVM as in
# compileMainNative's hybrid).  That native bnc binary then compiles
# each test package with --backend native and the test binary runs
# natively.
#
# Why this exists: the older `boot-comp_native_aa64` runner invokes
# `go run bootstrap → bnc --backend native` per package, paying the
# bootstrap-interpretation tax for every test compile.  Big packages
# (pkg/types ~20min, pkg/native/arm64 ~12min on macOS Apple Silicon)
# blow past CI's 30-min timeout one shard at a time.  This runner
# pays the bootstrap-interp tax once (building bnc itself), then
# every per-package test compile runs through the native bnc binary
# — fast because it's a real compiled program, not interpreted source.
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
    testbin=$("$BNC_NATIVE" --test --backend native -I "$BINATE_DIR" -L "$BINATE_DIR" --build-dir "$bdir" "$pkg" 2>&1)
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
