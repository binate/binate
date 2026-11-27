#!/bin/sh
# e2e/multi-file-main.sh — A main program of several files scopes its imports per
# file (spec pkg.import.scope), as a package does, on both execution paths: bnc
# compiling `bnc a.bn b.bn` and bni interpreting the directory.
#   1. Two files bind the name t to different packages (a.bn's to
#      pkg/builtins/testing, b.bn's to pkg/x); each file's t.… is its own package's,
#      and a generic a.bn declares prints through a.bn's t though b.bn instantiates
#      it.  The program builds and prints 1, 7 and 8.
#   2. A file that uses a package only the other file imports is rejected, at the
#      use: "b.bn:4:2: undefined: testing".
# The conformance runner builds a program from one main.bn, so this is where a
# program of several files is tested.
#
# bnc is a gen1 (BUILDER -> gen1, scripts/resolve-gen1.sh) and bni is built by it.
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_multifilemain.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Resolve a gen1 (the BUILDER compiling the checkout's cmd/bnc) and build
# bni with it.  resolve-gen1.sh caches gen1 per tree state, so an e2e run builds
# it once for every test. -----
GEN1_BNC="$("$BINATE_DIR/scripts/resolve-gen1.sh")"
if [ ! -x "$GEN1_BNC" ]; then
    echo "FAIL: no gen1 bnc"
    exit 1
fi
echo "Building bni..."
build_log=$("$GEN1_BNC" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --build-dir "$BUILD_DIR" \
    -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1)
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: bni build failed:"
    echo "$build_log"
    exit 1
fi

# ----- Fixtures -----
SRC="$TMP/src"
mkdir -p "$SRC/pkg/x" "$SRC/scoped" "$SRC/leak"
cat > "$SRC/pkg/x.bni" <<'EOF'
package "pkg/x"

func F() int
EOF
cat > "$SRC/pkg/x/x.bn" <<'EOF'
package "pkg/x"

func F() int { return 7 }
EOF
cat > "$SRC/scoped/a.bn" <<'EOF'
package "main"

import t "pkg/builtins/testing"

// Show prints x through this file's t, wherever it is instantiated.
func Show[T any](x T) {
	t.Println(x)
}

func main() {
	t.Println(1)
	g()
}
EOF
cat > "$SRC/scoped/b.bn" <<'EOF'
package "main"

import out "pkg/builtins/testing"
import t "pkg/x"

func g() {
	out.Println(t.F())
	Show[int](t.F() + 1)
}
EOF
cat > "$SRC/leak/a.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	testing.Println(1)
	g()
}
EOF
cat > "$SRC/leak/b.bn" <<'EOF'
package "main"

func g() {
	testing.Println(2)
}
EOF
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$SRC")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$SRC")"

FAILS=0
WANT_SCOPED='1
7
8'
LEAK_ERR='b\.bn:4:2: undefined: testing$'

# ----- 1. Each file's t is its own package's. -----
mkdir -p "$TMP/b1"
bnc_out=$(cd "$SRC/scoped" && "$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b1" \
    -o "$TMP/scoped-prog" a.bn b.bn 2>&1)
if [ ! -x "$TMP/scoped-prog" ]; then
    echo "FAIL: bnc did not build the program whose files bind t to different packages:"
    printf '%s\n' "$bnc_out" | tail -5
    FAILS=$((FAILS + 1))
else
    run_out=$("$TMP/scoped-prog" 2>&1)
    if [ "$run_out" = "$WANT_SCOPED" ]; then
        echo "PASS: bnc: each file's t is its own package's"
    else
        echo "FAIL: bnc: the program printed:"
        printf '%s\n' "$run_out" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
    fi
fi
bni_out=$(cd "$SRC" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" scoped 2>&1)
if [ "$bni_out" = "$WANT_SCOPED" ]; then
    echo "PASS: bni: each file's t is its own package's"
else
    echo "FAIL: bni: the program printed:"
    printf '%s\n' "$bni_out" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
fi

# ----- 2. A file may not use the other file's import. -----
mkdir -p "$TMP/b2"
bnc_out=$(cd "$SRC/leak" && "$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b2" \
    -o "$TMP/leak-prog" a.bn b.bn 2>&1)
bnc_rc=$?
if [ "$bnc_rc" -eq 0 ]; then
    echo "FAIL: bnc built a program whose b.bn uses a.bn's import"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bnc_out" | grep -qE "$LEAK_ERR"; then
    echo "FAIL: bnc failed, but not at b.bn's use of testing:"
    printf '%s\n' "$bnc_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bnc rejects a use of the other file's import"
fi
bni_out=$(cd "$SRC" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" leak 2>&1)
bni_rc=$?
if [ "$bni_rc" -eq 0 ]; then
    echo "FAIL: bni ran a program whose b.bn uses a.bn's import (it printed: $bni_out)"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bni_out" | grep -qE "$LEAK_ERR"; then
    echo "FAIL: bni failed, but not at b.bn's use of testing:"
    printf '%s\n' "$bni_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bni rejects a use of the other file's import"
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
