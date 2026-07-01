#!/bin/sh
# e2e/split-paths.sh — End-to-end test of the two-path package
# resolution (-I / --interface-path and -L / --impl-path) across all
# four tools that load Binate packages: bootstrap, bnc, bni, bnlint.
#
# Sets up a fixture where pkg/splitlib's interface lives in one root
# and its impl lives in a different root. No single root contains
# both, so every tool must search BniPath and ImplPath independently
# and pair the results across roots.
#
# Each tool resolves the fixture package purely via -I and -L (no
# extra root flag).  $BINATE_DIR is added on each path so
# pkg/bootstrap, pkg/builtins/rt, etc. resolve normally.
#
# Exit 0 on full pass; non-zero with per-tool diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/.." && pwd)/bootstrap"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
if [ ! -d "$BOOTSTRAP_DIR" ]; then
    echo "FAIL: bootstrap repo not found at $BOOTSTRAP_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_split_paths.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_ROOT="$TMP/bni-root"
IMPL_ROOT="$TMP/impl-root"
EMPTY_ROOT="$TMP/empty-root"
BUILD_DIR="$TMP/build"
mkdir -p "$BNI_ROOT/pkg" "$IMPL_ROOT/pkg/splitlib" "$EMPTY_ROOT" "$BUILD_DIR"

cat > "$BNI_ROOT/pkg/splitlib.bni" <<'EOF'
package "pkg/splitlib"

func Greet()
EOF

cat > "$IMPL_ROOT/pkg/splitlib/splitlib.bn" <<'EOF'
package "pkg/splitlib"

func Greet() {
    println("split-paths-ok")
}
EOF

cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/splitlib"

func main() {
    splitlib.Greet()
}
EOF

EXPECTED="split-paths-ok"
PASSES=0
FAILS=0
FAIL_NAMES=""

check() {
    label="$1"
    actual="$2"
    if [ "$actual" = "$EXPECTED" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected: $EXPECTED"
        echo "  actual:   $actual"
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# ----- bootstrap (Go interpreter) ---------------------------------
# Bootstrap accepts -I/-L directly (Stage 5).
actual=$(cd "$BOOTSTRAP_DIR" && go run . \
    -I "$BNI_ROOT:$BINATE_DIR" -L "$IMPL_ROOT:$BINATE_DIR" \
    "$TMP/main.bn" 2>&1) || true
check "bootstrap" "$actual"

# ----- bnc (compile to native binary, then run) -------------------
# The resolved BUILDER drives cmd/bnc; bnc itself sees the -I/-L
# after `--` as its own user args.
BNC_BIN="$TMP/bnc-bin"
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
# The fixture is compiled by the BUILDER directly, so it is emitted with
# the BUILDER's mangling scheme. Link the BUILDER's OWN bundled runtime
# (same scheme) rather than the checkout runtime/binate_runtime.c, which
# tracks current-source mangling and can name its symbols differently
# from the BUILDER (e.g. across a mangle-scheme change) — pairing a
# BUILDER-scheme compile against the checkout runtime then fails to link
# with undefined runtime symbols (bn_..._Write, etc.).
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
bnc_compile_log=$("$BUILDER" -I "$BINATE_DIR:$BINATE_DIR/ifaces/core:$BINATE_DIR/ifaces/stdlib" -L "$BINATE_DIR:$BINATE_DIR/impls/core/common:$BINATE_DIR/impls/core/libc:$BINATE_DIR/impls/stdlib" \
    "$BINATE_DIR/cmd/bnc" -- \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$BNI_ROOT")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$IMPL_ROOT")" \
    --runtime "$BUILDER_LIB/runtime/binate_runtime.c" \
    --build-dir "$BUILD_DIR" -o "$BNC_BIN" "$TMP/main.bn" 2>&1) || true
if [ -x "$BNC_BIN" ]; then
    actual=$("$BNC_BIN" 2>&1) || true
else
    actual="COMPILE_ERROR: $bnc_compile_log"
fi
check "bnc" "$actual"

# ----- bni (bytecode VM) ------------------------------------------
# bni is skipped here: cmd/bni imports pkg/binate/vm, which uses float
# literals that the bootstrap lexer doesn't recognize, so we can't
# interpret bni via bootstrap. To cover bni we would have to first
# compile it (via builder-comp) and then invoke the binary against the
# fixture. That belongs in the broader e2e build-out — see the
# "Build out e2e testing" entry in explorations/claude-todo.md.
echo "SKIP: bni (bootstrap can't interp cmd/bni — needs builder-comp build)"

# ----- bnlint (lint pkg/splitlib via -I/-L) -----------------------
# bnlint is no longer required to be bootstrap-runnable, so we build
# it via bnc first and exercise the resulting binary.  A clean lint =
# no diagnostic output.
BNLINT_BIN="$TMP/bnlint-bin"
bnlint_build_log=$("$BINATE_DIR/scripts/build-bnlint.sh" \
    -o "$BNLINT_BIN" 2>&1) || true
if [ ! -x "$BNLINT_BIN" ]; then
    echo "FAIL: bnlint"
    echo "  build error: $bnlint_build_log"
    FAILS=$((FAILS + 1))
    FAIL_NAMES="$FAIL_NAMES bnlint"
else
    bnlint_out=$("$BNLINT_BIN" \
        -I "$BNI_ROOT:$BINATE_DIR" -L "$IMPL_ROOT:$BINATE_DIR" \
        pkg/splitlib 2>&1) || true
    if [ -z "$bnlint_out" ]; then
        echo "PASS: bnlint"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: bnlint"
        echo "  expected: <empty>"
        echo "  actual:   $bnlint_out"
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES bnlint"
    fi
fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
