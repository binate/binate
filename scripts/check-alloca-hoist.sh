#!/bin/sh
# check-alloca-hoist.sh — sweep a corpus of .bn programs for the
# "every alloca is hoisted to the function entry block" invariant
# (see conformance/check-alloca-hoist.py for the why).  Compiles each
# program with `bnc --emit-llvm` and runs the checker on the IR.  This is
# the construct-agnostic, compile-time detector for the per-iteration
# native-stack-leak class: any lowering that emits an un-hoisted alloca
# trips it, without needing a high-iteration runtime repro.
#
# Usage:
#   scripts/check-alloca-hoist.sh [FILE.bn ...]
# With no args, sweeps the single-file conformance corpus (top-level
# NNN_*.bn, matrix/**, regressions/**).  Requires a built compiler; set
# BNC to reuse one, else a gen1 is built.  Exit 1 if any violation.
set -e
BINATE_DIR="${BINATE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$BINATE_DIR"
CHECKER="$BINATE_DIR/conformance/check-alloca-hoist.py"

if [ -z "$BNC" ]; then
    . "$BINATE_DIR/scripts/lib/build-compilers.sh"
    build_gen1
    BNC="$GEN1_COMPILER"
fi

IFLAGS="-I $BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib"
LFLAGS="-L $BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib/common"

if [ "$#" -gt 0 ]; then
    FILES="$*"
else
    # Single-file cells only (multi-package NNN_name/main.bn dirs need
    # per-package -I and are skipped; the single-file corpus already
    # exercises the full construct space).
    FILES=$(find conformance -name '*.bn' \
        -not -path '*/pkg/*' -not -name 'main.bn' | sort)
fi

violations=0
checked=0
skipped=0
bdir="$(mktemp -d)"
trap 'rm -rf "$bdir"' EXIT
for f in $FILES; do
    ll="$bdir/out.ll"
    if "$BNC" --emit-llvm $IFLAGS $LFLAGS --build-dir "$bdir" "$f" \
            > "$ll" 2>/dev/null; then
        checked=$((checked + 1))
        if ! python3 "$CHECKER" --name "$f" < "$ll"; then
            violations=$((violations + 1))
        fi
    else
        # Cells that don't compile standalone (multi-package deps, .error
        # cells, etc.) — not this checker's concern.
        skipped=$((skipped + 1))
    fi
done

echo "check-alloca-hoist: $checked checked, $skipped skipped (uncompilable standalone), $violations with violations"
[ "$violations" -eq 0 ]
