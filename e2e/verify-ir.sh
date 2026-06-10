#!/bin/sh
# E2E: run the structural IR verifier over the whole self-hosted toolchain.
#
# Builds gen1 (the BUILDER compiles cmd/bnc — no flag on this leg, since the
# pinned BUILDER bnc predates --verify-ir), then uses gen1 with --verify-ir
# to compile each toolchain entry point — cmd/{bnc,bni,bnas,bnlint} — and
# their full transitive dependency closure (≈ the entire codebase: ast,
# lexer, parser, types, ir, codegen, native, vm, asm, mangle, loader, the
# runtime, the stdlib …).  A normal `bnc -o` build runs IR-gen on every
# function in that closure, so --verify-ir checks the lot; a malformed-IR
# regression (the ctx.CurBlock-desync class) aborts the compile and fails
# this test at IR-gen, instead of silently miscompiling.
#
# This is the self-compiled-IR coverage the conformance --verify-ir path
# cannot reach: there BINATE_FLAGS flows only to the test-program compile
# leg, never to the build of the compiler/toolchain itself.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$BINATE_DIR/scripts/lib/build-compilers.sh"

# BUILDER → gen1 (gen1 is built from the current tree, so it supports
# --verify-ir; the BUILDER leg itself does not get the flag).
build_gen1

rc=0
for cmd in bnc bni bnas bnlint; do
    bdir="$(mktemp -d)"
    out="$(mktemp -u)"
    echo "=== gen1 --verify-ir: cmd/$cmd (+ transitive deps) ==="
    if "$GEN1_COMPILER" --verify-ir \
            -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
            -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
            --build-dir "$bdir" -o "$out" "$BINATE_DIR/cmd/$cmd"; then
        echo "OK: cmd/$cmd verified clean"
    else
        echo "FAIL: cmd/$cmd — --verify-ir found malformed IR (or the build failed)"
        rc=1
    fi
    rm -rf "$bdir" "$out"
done

if [ "$rc" -eq 0 ]; then
    echo "PASS: toolchain IR verified clean (bnc, bni, bnas, bnlint)"
fi
exit "$rc"
