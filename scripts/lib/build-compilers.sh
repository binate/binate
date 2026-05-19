#!/bin/sh
# Shared helpers for building gen1/gen2 compilers and compiled interpreters.
# Source this from runner scripts.
#
# Each helper allocates its own --build-dir under /tmp via mktemp so
# concurrent test runs don't clobber each other's intermediate .ll/.o
# files. The dirs are tracked in BUILD_DIRS and removed by
# cleanup_compilers.

# BUILD_DIRS holds the per-helper build directories created during this
# runner_setup; cleanup_compilers tears them down.
BUILD_DIRS=""

# _new_build_dir prints a fresh build dir under /tmp (caller is
# responsible for tracking + removing it via cleanup_compilers).
_new_build_dir() {
    d=$(mktemp -d "/tmp/binate_build_XXXXXX")
    BUILD_DIRS="$BUILD_DIRS $d"
    echo "$d"
}

# _resolve_builder caches the BUILDER_VERSION binary at first use and
# echoes its path.  All build_* helpers go through this so the
# fetcher's per-test rebuild check (a stat of bootstrap's .go files
# against the cache) runs once per runner_setup rather than per call.
_resolve_builder() {
    if [ -z "$_BUILDER_BIN" ]; then
        _BUILDER_BIN="$("$BINATE_DIR/scripts/fetch-builder.sh")"
    fi
    echo "$_BUILDER_BIN"
}

# Build gen1 compiler (boot-comp compiles cmd/bnc → gen1 binary)
# Sets GEN1_COMPILER to the path.
build_gen1() {
    GEN1_COMPILER="/tmp/binate_gen1_compiler_$$"
    GEN1_BUILD_DIR="$(_new_build_dir)"
    echo "Building gen1 compiler..."
    builder="$(_resolve_builder)"
    build_out=$("$builder" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" --build-dir "$GEN1_BUILD_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN1_COMPILER" ]; then
        echo "ERROR: Failed to build gen1 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen1 compiler ready: $GEN1_COMPILER"
}

# Build gen2 compiler (gen1 compiles cmd/bnc → gen2 binary)
# Requires GEN1_COMPILER to be set (call build_gen1 first).
# Sets GEN2_COMPILER to the path.
build_gen2() {
    GEN2_COMPILER="/tmp/binate_gen2_compiler_$$"
    GEN2_BUILD_DIR="$(_new_build_dir)"
    echo "Building gen2 compiler..."
    build_out=$("$GEN1_COMPILER" --root "$BINATE_DIR" --build-dir "$GEN2_BUILD_DIR" -o "$GEN2_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN2_COMPILER" ]; then
        echo "ERROR: Failed to build gen2 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen2 compiler ready: $GEN2_COMPILER"
}

# Build a bnc binary using the native AArch64 backend (bootstrap
# interpreter runs cmd/bnc with --backend native, asking it to compile
# cmd/bnc itself).  Dependency modules of bnc still go through the
# LLVM path (compileMainNative falls back to LLVM for everything that
# isn't the main module); the cmd/bnc module is the only one emitted
# via the native aarch64 path.  The resulting binary is a native
# program that's much faster than re-running bootstrap-interp-bnc for
# every test package — used by the boot-comp_native_aa64-comp_native_aa64
# runner to amortise the bootstrap-interp tax over many test compiles.
# Sets BNC_NATIVE to the path.
build_bnc_native_aa64() {
    BNC_NATIVE="/tmp/binate_bnc_native_aa64_$$"
    BNC_NATIVE_BUILD_DIR="$(_new_build_dir)"
    echo "Building bnc with native aarch64 backend..."
    builder="$(_resolve_builder)"
    build_out=$("$builder" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --backend native --root "$BINATE_DIR" --build-dir "$BNC_NATIVE_BUILD_DIR" -o "$BNC_NATIVE" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$BNC_NATIVE" ]; then
        echo "ERROR: Failed to build bnc (native aarch64):"
        echo "$build_out"
        exit 1
    fi
    echo "bnc (native aarch64) ready: $BNC_NATIVE"
}

# Build compiled interpreter (bni, a bytecode VM) using bootstrap→bnc.
# Sets COMPILED_INTERP to the path.
build_interp_boot_comp() {
    COMPILED_INTERP="/tmp/binate_compiled_interp_$$"
    INTERP_BUILD_DIR="$(_new_build_dir)"
    echo "Building compiled interpreter..."
    builder="$(_resolve_builder)"
    build_out=$("$builder" -root "$BINATE_DIR" "$BINATE_DIR/cmd/bnc" -- --root "$BINATE_DIR" --build-dir "$INTERP_BUILD_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

# Build compiled interpreter (bni, a bytecode VM) using a given compiler.
# $1 = compiler binary path
# Sets COMPILED_INTERP to the path.
build_interp() {
    local compiler="$1"
    COMPILED_INTERP="/tmp/binate_compiled_interp_$$"
    INTERP_BUILD_DIR="$(_new_build_dir)"
    echo "Building compiled interpreter..."
    build_out=$("$compiler" --root "$BINATE_DIR" --build-dir "$INTERP_BUILD_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

# Cleanup helper — removes all temp binaries and build dirs.
cleanup_compilers() {
    rm -f "$GEN1_COMPILER" "$GEN2_COMPILER" "$COMPILED_INTERP" "$BNC_NATIVE"
    for d in $BUILD_DIRS; do
        rm -rf "$d"
    done
    BUILD_DIRS=""
}
