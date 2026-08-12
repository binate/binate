#!/bin/sh
# e2e/env-paths.sh — End-to-end test of the environment-variable fallback for
# two-path package resolution (Stage 7 of plan-package-search-paths).
#
# When a tool is given no -I / -L for a search path, it takes that path from the
# environment: BINATE_PACKAGE_INTERFACE_PATH / BINATE_PACKAGE_IMPL_PATH (long
# form) or BINATE_BNI_PATH / BINATE_IMPL_PATH (short aliases).  This exercises
# the wiring end to end — the piece unit tests can't reach, since the tools read
# the real process environment — across all three tools that resolve packages:
# bnc, bni, bnlint.
#
# Fixture: pkg/splitlib's interface lives in one root and its impl in another,
# so resolution must pair BniPath and ImplPath across roots (as in split-paths).
# Each tool is built FROM SOURCE (the frozen BUILDER predates this feature).
#
# Checks per tool: (1) env supplies both paths, no flags → resolves; and one of
#   (2) a correct -I/-L overrides a bogus env value (CLI wins per path), or
#   (3) the short aliases work when the long form is unset.
#
# Exit 0 on full pass; non-zero with per-check diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
PATHS="$BINATE_DIR/scripts/binate-paths.sh"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_env_paths.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_ROOT="$TMP/bni-root"
IMPL_ROOT="$TMP/impl-root"
BOGUS="$TMP/bogus"
BUILD_DIR="$TMP/build"
mkdir -p "$BNI_ROOT/pkg" "$IMPL_ROOT/pkg/envlib" "$BOGUS" "$BUILD_DIR"

cat > "$BNI_ROOT/pkg/envlib.bni" <<'EOF'
package "pkg/envlib"

func Greet()
EOF

cat > "$IMPL_ROOT/pkg/envlib/envlib.bn" <<'EOF'
package "pkg/envlib"

import "pkg/builtins/testing"

func Greet() {
    testing.Println("env-paths-ok")
}
EOF

cat > "$TMP/main.bn" <<'EOF'
package "main"

import "pkg/envlib"

func main() {
    envlib.Greet()
}
EOF

# The interface/impl search paths that resolve the fixture: the checkout base
# (for pkg/builtins/rt, pkg/std/*, testing, ...) with the fixture roots
# prepended.  Colon-separated — the exact shape the env vars take.
IFACE_PATHS="$("$PATHS" --iface --base "$BINATE_DIR" --prepend "$BNI_ROOT")"
IMPL_PATHS="$("$PATHS" --impl --base "$BINATE_DIR" --prepend "$IMPL_ROOT")"

EXPECTED="env-paths-ok"
PASSES=0
FAILS=0
FAIL_NAMES=""

pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && echo "  $2"
    FAILS=$((FAILS + 1))
    FAIL_NAMES="$FAIL_NAMES $1"
}
check_out() { # label expected actual
    if [ "$3" = "$2" ]; then pass "$1"; else
        fail "$1" "expected: $2"; echo "  actual:   $3"
    fi
}

# ----- build the three tools from source ---------------------------
BNC_BIN="$TMP/bnc"
BNI_BIN="$TMP/bni"
BNLINT_BIN="$TMP/bnlint"
build_log="$TMP/build.log"
build_tool() { # script out
    if ! "$BINATE_DIR/scripts/$1" -o "$2" >>"$build_log" 2>&1; then
        fail "build:$1" "see build log below"
        cat "$build_log" >&2
        return 1
    fi
    return 0
}
build_tool build-bnc.sh   "$BNC_BIN"   || { echo "=== aborting: bnc build failed ==="; exit 1; }
build_tool build-bni.sh   "$BNI_BIN"   || { echo "=== aborting: bni build failed ==="; exit 1; }
build_tool build-bnlint.sh "$BNLINT_BIN" || { echo "=== aborting: bnlint build failed ==="; exit 1; }

# ----- bnc: env resolves, and -I/-L overrides a bogus env ----------
# (1) env supplies both paths, no -I/-L.
actual=$(env BINATE_PACKAGE_INTERFACE_PATH="$IFACE_PATHS" \
             BINATE_PACKAGE_IMPL_PATH="$IMPL_PATHS" \
         "$BNC_BIN" --build-dir "$BUILD_DIR" -o "$TMP/bnc-env" "$TMP/main.bn" >/dev/null 2>&1 \
             && "$TMP/bnc-env" 2>&1 || echo "COMPILE_ERROR")
check_out "bnc (env)" "$EXPECTED" "$actual"
# (2) correct -I/-L wins over a bogus env value.
actual=$(env BINATE_PACKAGE_INTERFACE_PATH="$BOGUS" BINATE_PACKAGE_IMPL_PATH="$BOGUS" \
         "$BNC_BIN" --build-dir "$BUILD_DIR" -o "$TMP/bnc-cli" \
             -I "$IFACE_PATHS" -L "$IMPL_PATHS" "$TMP/main.bn" >/dev/null 2>&1 \
             && "$TMP/bnc-cli" 2>&1 || echo "COMPILE_ERROR")
check_out "bnc (-I/-L overrides env)" "$EXPECTED" "$actual"

# ----- bni: env resolves (VM runs the program) ---------------------
actual=$(env BINATE_PACKAGE_INTERFACE_PATH="$IFACE_PATHS" BINATE_PACKAGE_IMPL_PATH="$IMPL_PATHS" \
         "$BNI_BIN" "$TMP/main.bn" 2>&1 || true)
check_out "bni (env)" "$EXPECTED" "$actual"

# ----- bnlint: env resolves, and the short aliases work ------------
# A clean lint produces no output.
out=$(env BINATE_PACKAGE_INTERFACE_PATH="$IFACE_PATHS" BINATE_PACKAGE_IMPL_PATH="$IMPL_PATHS" \
      "$BNLINT_BIN" pkg/envlib 2>&1 || true)
if [ -z "$out" ]; then pass "bnlint (env)"; else fail "bnlint (env)" "unexpected: $out"; fi
# Short aliases (long form unset).
out=$(env BINATE_BNI_PATH="$IFACE_PATHS" BINATE_IMPL_PATH="$IMPL_PATHS" \
      "$BNLINT_BIN" pkg/envlib 2>&1 || true)
if [ -z "$out" ]; then pass "bnlint (alias)"; else fail "bnlint (alias)" "unexpected: $out"; fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
