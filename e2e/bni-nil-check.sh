#!/bin/sh
# e2e/bni-nil-check.sh — End-to-end check of opt-in nil-pointer-deref checking
# (Plan 2 nil-deref; explorations/plan-nil-check-opt-in.md).  A nil deref is
# normally a bare load through address 0 — a SEGV, C-like.  With `--check-nil`
# the VM instead raises a RECOVERABLE fault: it prints
# "runtime error: nil pointer dereference" and exits non-zero, without a crash.
#
# This pins BOTH halves of the opt-in contract on the real `bni` binary:
#   1. `bni --check-nil prog.bn` on a nil deref → the fault message + non-zero exit.
#   2. `bni prog.bn` (no flag) → NO such message (default off: the check is not
#      emitted, so the deref just crashes) — proving the feature is truly opt-in
#      and a plain run stays byte-identical to pre-feature.
#
# bni is built via builder-comp (BUILDER -> gen1 -> bni), same as e2e/repl.sh
# and e2e/bni-test-fault.sh — cmd/bni isn't bootstrap-runnable (pkg/binate/vm
# uses floats).
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_nilcheck.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Build bni via builder-comp (BUILDER -> gen1 -> bni) -----
# See e2e/repl.sh / scripts/build-bni.sh for the two-stage rationale.
echo "Building bni via builder-comp (BUILDER -> gen1 -> bni)..."
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

# Transitional Linux gen1-link shim (BUILDER bnc-0.0.14 emits the iv-dispatch
# thunks STRONG); accept the ODR-identical dups.  Remove at BUILDER >= bnc-0.0.15.
# Full rationale: scripts/lib/build-compilers.sh build_gen1 + claude-todo.
gen1_dupthunk_flag=""
[ "$(uname -s)" = Linux ] && gen1_dupthunk_flag="--cflag -Wl,--allow-multiple-definition"
gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR" --prepend "$BINATE_DIR/ifaces/toolchain")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --build-dir "$GEN1_DIR/build" \
    $gen1_dupthunk_flag \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc" 2>&1)
if [ ! -x "$GEN1_BNC" ]; then
    echo "FAIL: gen1 build failed:"
    echo "$gen1_log"
    exit 1
fi

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
echo "Built: $BNI_BIN"

# ----- Fixture: a program that dereferences a nil managed pointer. -----
cat > "$TMP/nilderef.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

type Node struct {
	val int
}

func main() {
	// Read a field through a nil managed pointer.  With --check-nil the VM
	// raises a recoverable "nil pointer dereference" fault (message + non-zero
	// exit); without it this is a bare load through address 0 -> SEGV.  The
	// field read rides through testing.Println (a `...*any` variadic): the
	// implicit value-borrow of `p.val` nil-checks the base pointer, so the
	// nil deref is detected.
	var p @Node = nil
	testing.Println(p.val)
}
EOF

IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

fail=0

# ----- 1. With --check-nil: the fault is recovered (message + non-zero exit). -----
checked_out=$("$BNI_BIN" --check-nil -I "$IFACES" -L "$IMPLS" -main-file "$TMP/nilderef.bn" 2>&1)
checked_ec=$?
if ! printf '%s' "$checked_out" | grep -q "nil pointer dereference"; then
    echo "FAIL: 'bni --check-nil' on a nil deref must print 'nil pointer dereference'"
    fail=1
fi
if [ "$checked_ec" -eq 0 ]; then
    echo "FAIL: 'bni --check-nil' on a nil deref must exit non-zero (got exit 0)"
    fail=1
fi

# ----- 2. Without the flag (default off): the check is NOT emitted, so there is -----
# no recovery message — the deref just crashes.  Proves the feature is opt-in.
plain_out=$("$BNI_BIN" -I "$IFACES" -L "$IMPLS" -main-file "$TMP/nilderef.bn" 2>&1 || true)
if printf '%s' "$plain_out" | grep -q "nil pointer dereference"; then
    echo "FAIL: a plain 'bni' run (no --check-nil) must NOT emit a nil-check message (default off)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "--- 'bni --check-nil' output was:"
    printf '%s\n' "$checked_out" | sed 's/^/    /'
    echo "--- plain 'bni' output was:"
    printf '%s\n' "$plain_out" | sed 's/^/    /'
    exit 1
fi

echo "PASS: --check-nil recovers a nil deref (message + non-zero exit); default off stays C-like"
exit 0
