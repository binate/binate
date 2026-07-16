#!/bin/sh
# E2E: build bnlint from the CURRENT source tree and lint every real package
# (the same target set + skip list as scripts/hygiene/lint.sh).
#
# scripts/hygiene/lint.sh PREFERS the pinned CHECK_TOOLS bnlint bundle
# (often the same tool as the BUILDER), so on a normal run it exercises that
# pinned bnlint — NOT the bnlint built from this tree.  A regression in the
# tree's bnlint (a crash, a spurious diagnostic, or a missed one) would slip
# past hygiene entirely.  This e2e forces lint.sh to build bnlint from current
# source (--from-source) and lints the whole repo with it, so the tree's bnlint
# is actually TESTED against real code.
#
# A clean tree exits 0; a bnlint regression that mis-lints any package exits
# non-zero and fails this test.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if "$BINATE_DIR/scripts/hygiene/lint.sh" --from-source; then
    echo "PASS: current-tree bnlint lints the whole repo clean"
else
    echo "FAIL: current-tree bnlint reported diagnostics (or failed to build)"
    exit 1
fi
