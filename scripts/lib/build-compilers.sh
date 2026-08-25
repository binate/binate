#!/bin/sh
# Shared helpers for building gen1/gen2 compilers and compiled interpreters.
# Source this from runner scripts.
#
# All compiler binaries and build directories for one runner_setup live
# under a single unique session directory (mktemp -d).  This keeps
# concurrent test runs in different worker sessions from colliding in the
# shared /tmp namespace: no PID-reuse clashes on the old
# `/tmp/binate_*_$$` names, and no `ls /tmp/binate_*` ambiguity when a
# session needs to find ITS OWN compiler.  cleanup_compilers removes the
# whole session dir.

# _COMPILERS_DIR is the per-runner_setup session directory; lazily created
# on first use and reused for every gen1/gen2/interp binary + build dir.
#
# _ensure_compilers_dir must be called DIRECTLY (never inside a $(...)
# command substitution): the `_COMPILERS_DIR=...` assignment has to land in
# the caller's shell.  In a subshell it would set a throwaway copy, leaving
# the real _COMPILERS_DIR empty — so each use would spawn a fresh dir and
# cleanup_compilers would never find them.
_COMPILERS_DIR=""
_ensure_compilers_dir() {
    if [ -z "$_COMPILERS_DIR" ]; then
        _COMPILERS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/binate_compilers_XXXXXX")
    fi
}

# BUILD_DIRS holds the per-helper build directories created during this
# runner_setup; cleanup_compilers tears them down (removing the session
# dir would too, but the list is kept for explicitness).
BUILD_DIRS=""

# _new_build_dir prints a fresh build dir inside the session dir (caller is
# responsible for tracking + removing it via cleanup_compilers).
_new_build_dir() {
    _ensure_compilers_dir
    d=$(mktemp -d "$_COMPILERS_DIR/build_XXXXXX")
    BUILD_DIRS="$BUILD_DIRS $d"
    echo "$d"
}

# _resolve_builder caches the BUILDER_VERSION binary at first use and
# echoes its path.  All build_* helpers go through this so the fetcher
# (which resolves + sha256-verifies the release bundle) runs once per
# runner_setup rather than per call.
_resolve_builder() {
    if [ -z "$_BUILDER_BIN" ]; then
        _BUILDER_BIN="$("$BINATE_DIR/scripts/fetch-builder.sh")"
    fi
    echo "$_BUILDER_BIN"
}

# _resolve_builder_lib caches and echoes the builder bundle's stdlib
# root.  Builder-link callers append this to -I/-L so a bnc-X.Y.Z
# bundle can supply stdlib pieces missing from the current checkout
# (or, when the user wants the bundled version specifically, override
# their checkout by prepending the bundle dir instead).
_resolve_builder_lib() {
    if [ -z "$_BUILDER_LIB" ]; then
        _BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
    fi
    echo "$_BUILDER_LIB"
}

# Build gen1 compiler (builder-comp compiles cmd/bnc → gen1 binary)
# Sets GEN1_COMPILER to the path.
build_gen1() {
    _ensure_compilers_dir
    GEN1_COMPILER="$_COMPILERS_DIR/gen1_compiler"
    GEN1_BUILD_DIR="$(_new_build_dir)"
    echo "Building gen1 compiler..."
    builder="$(_resolve_builder)"
    blib="$(_resolve_builder_lib)"
    # gen1 = the BUILDER compiling cmd/bnc.  The bnc source cone (cmd/bnc + its
    # deps) may only use language, core-lib (builtin), and stdlib features that
    # exist in the BUILDER — the BUILDER-compatibility constraint — so its
    # builtin + stdlib deps resolve entirely from the BUILDER's frozen bundle
    # (`--base "$blib"`, which also supplies the linked C runtime).
    # Pulling those from source instead would let cmd/bnc accidentally use a
    # not-yet-in-BUILDER feature (e.g. `same` in std/errors, added after
    # bnc-0.0.7) and fail the build.  Only pkg/binate (the compiler's own code)
    # comes from source — `--prepend "$BINATE_DIR"`, which is
    # also the primaryRoot and shadows the stale pkg/binate the bundle ships.
    # There is deliberately NO source fallback: mixing source and bundle copies
    # of interdependent packages (source A built against the BUILDER's B) is
    # incoherent.  If cmd/bnc needs a feature the BUILDER lacks, bump
    # BUILDER_VERSION.  gen1's objects carry the BUILDER's mangling/ABI; gen1's
    # OUTPUTS (gen2, tests, conformance) are emitted by gen1 and link the
    # checkout runtime.
    # e2e/{repl,os-args}.sh + scripts/build-*.sh use the same invocation form.
    build_out=$("$builder" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$blib" --prepend "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$blib" --prepend "$BINATE_DIR")" --build-dir "$GEN1_BUILD_DIR" -o "$GEN1_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
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
    _ensure_compilers_dir
    GEN2_COMPILER="$_COMPILERS_DIR/gen2_compiler"
    GEN2_BUILD_DIR="$(_new_build_dir)"
    echo "Building gen2 compiler..."
    build_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$GEN2_BUILD_DIR" -o "$GEN2_COMPILER" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$GEN2_COMPILER" ]; then
        echo "ERROR: Failed to build gen2 compiler:"
        echo "$build_out"
        exit 1
    fi
    echo "Gen2 compiler ready: $GEN2_COMPILER"
}

# Build a bnc binary using the native AArch64 backend — current-tree
# cmd/bnc compiled via the LLVM path (GEN1_COMPILER) with --backend
# native, asking it to compile cmd/bnc itself.  Dependency modules
# of bnc still go through the LLVM path (compileMainNative falls
# back to LLVM for everything that isn't the main module); only the
# cmd/bnc main module gets the native aarch64 lowering.  The resulting
# binary is much faster than re-running gen1 for every test compile
# — used by the builder-comp_native_aa64-comp_native_aa64 runner.
# Calls build_gen1 if GEN1_COMPILER isn't set, so the "first comp"
# is always current-tree cmd/bnc rather than the BUILDER directly
# (under bnc-* BUILDER, bnc-X.Y.Z's native backend may lag behind
# current-tree features otherwise).
# Sets BNC_NATIVE to the path.
build_bnc_native_aa64() {
    if [ -z "$GEN1_COMPILER" ]; then build_gen1; fi
    _ensure_compilers_dir
    BNC_NATIVE="$_COMPILERS_DIR/bnc_native_aa64"
    BNC_NATIVE_BUILD_DIR="$(_new_build_dir)"
    echo "Building bnc with native aarch64 backend..."
    build_out=$("$GEN1_COMPILER" --backend native -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --build-dir "$BNC_NATIVE_BUILD_DIR" -o "$BNC_NATIVE" "$BINATE_DIR/cmd/bnc" 2>&1)
    if [ ! -x "$BNC_NATIVE" ]; then
        echo "ERROR: Failed to build bnc (native aarch64):"
        echo "$build_out"
        exit 1
    fi
    echo "bnc (native aarch64) ready: $BNC_NATIVE"
}

# Build compiled interpreter (bni, a bytecode VM) using current-tree
# cmd/bnc (GEN1_COMPILER) to compile current-tree cmd/bni.  Calls
# build_gen1 first so the "comp" link is always current-tree rather
# than the BUILDER directly.
# Sets COMPILED_INTERP to the path.
build_interp_boot_comp() {
    if [ -z "$GEN1_COMPILER" ]; then build_gen1; fi
    build_interp "$GEN1_COMPILER"
}

# Build compiled interpreter (bni, a bytecode VM) using a given compiler.
# $1 = compiler binary path
# Sets COMPILED_INTERP to the path.
#
# Built --cflag -O2 (the release opt level — see scripts/build-bni.sh): this is
# the VM lanes' execution vehicle, and on the double-VM lane (-int-int) it runs
# cmd/bni's whole load pipeline (parse→typecheck→IR→bytecode) plus the interpreter
# dispatch loop, all compute-bound.  clang defaults to -O0 when bnc passes no -O,
# and -O0 native here is several times slower — enough to blow the per-shard
# timeout.  The one-time -O2 build cost (once per shard in runner_setup) is dwarfed
# by the faster execution across the shard.
build_interp() {
    local compiler="$1"
    _ensure_compilers_dir
    COMPILED_INTERP="$_COMPILERS_DIR/compiled_interp"
    INTERP_BUILD_DIR="$(_new_build_dir)"
    echo "Building compiled interpreter (-O2)..."
    build_out=$("$compiler" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --cflag -O2 --build-dir "$INTERP_BUILD_DIR" -o "$COMPILED_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$COMPILED_INTERP" ]; then
        echo "ERROR: Failed to build compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "Compiled interpreter ready: $COMPILED_INTERP"
}

# Build the compiled interpreter (bni) CROSS-COMPILED for arm32-linux, using
# current-tree cmd/bnc (GEN1_COMPILER) with --target arm32-linux.  The result is
# a 32-bit-HOST bytecode VM (host int == 4 bytes); because cmd/bni bakes in
# ConfigForTarget("") it interprets 32-bit-target bytecode — so running it (under
# qemu-arm) exercises the VM's 32-bit-host paths.  Requires the arm32 cross-
# toolchain (clang -target arm-linux-gnueabihf); NOT buildable on macOS.  Run it
# via conformance/runners/builder-comp_arm32_linux_int.sh.
# Sets ARM32_INTERP to the path.
build_interp_arm32() {
    if [ -z "$GEN1_COMPILER" ]; then build_gen1; fi
    _ensure_compilers_dir
    ARM32_INTERP="$_COMPILERS_DIR/arm32_interp"
    ARM32_INTERP_BUILD_DIR="$(_new_build_dir)"
    echo "Cross-building compiled interpreter (bni) for arm32-linux..."
    build_out=$("$GEN1_COMPILER" -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target arm32-linux)" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" --target arm32-linux --build-dir "$ARM32_INTERP_BUILD_DIR" -o "$ARM32_INTERP" "$BINATE_DIR/cmd/bni" 2>&1)
    if [ ! -x "$ARM32_INTERP" ]; then
        echo "ERROR: Failed to cross-build arm32 compiled interpreter:"
        echo "$build_out"
        exit 1
    fi
    echo "arm32 compiled interpreter ready: $ARM32_INTERP"
}

# Cleanup helper — removes the session dir (which holds every compiler
# binary + build dir).  The explicit BUILD_DIRS / binary removals are
# redundant with the session-dir rm but kept as a belt-and-suspenders in
# case a caller pointed a path elsewhere.
cleanup_compilers() {
    rm -f "$GEN1_COMPILER" "$GEN2_COMPILER" "$COMPILED_INTERP" "$BNC_NATIVE"
    for d in $BUILD_DIRS; do
        rm -rf "$d"
    done
    BUILD_DIRS=""
    if [ -n "$_COMPILERS_DIR" ]; then
        rm -rf "$_COMPILERS_DIR"
        _COMPILERS_DIR=""
    fi
}
