#!/bin/sh
# e2e/bni-test-nil.sh — End-to-end check that `bni --test` enables opt-in
# nil-pointer-deref checking (plan-nil-check-opt-in.md N3), so a Test* that
# dereferences a nil pointer is reported as a recoverable FAILURE (message +
# non-zero exit) instead of SEGV-crashing the whole test runner.
#
# Unlike bounds/divide/shift faults (always on in the VM), nil-checking is
# opt-in: `bni --test` turns it on unconditionally (a test suite wants host
# survival). This test would therefore SEGV the runner — no "nil pointer
# dereference" message, TestGood never reached — if the `--test` path failed to
# set EmitNilChecks. So it directly validates that wiring. Sibling of
# e2e/bni-test-fault.sh (which covers the bounds-check fault).
#
# The fixture has TWO tests: one that derefs nil (faults) and one that passes.
# A correct runner prints `--- FAIL:` for the faulting one with the runtime-error
# message, `--- PASS:` for the good one (proving it kept going past the fault),
# and exits non-zero.
#
# bni is built via builder-comp (BUILDER -> gen1 -> bni), same as e2e/repl.sh /
# e2e/bni-test-fault.sh — cmd/bni isn't bootstrap-runnable (pkg/binate/vm uses
# floats).
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_testnil.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Build bni via builder-comp (BUILDER -> gen1 -> bni) -----
echo "Building bni via builder-comp (BUILDER -> gen1 -> bni)..."
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --runtime "$BUILDER_RUNTIME" \
    --build-dir "$GEN1_DIR/build" \
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
    --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
    --build-dir "$BUILD_DIR" \
    -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1)
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: bni build failed:"
    echo "$build_log"
    exit 1
fi
echo "Built: $BNI_BIN"

# ----- Fixture: a package with a nil-deref Test and a passing Test. -----
mkdir -p "$TMP/pkg/faultynil"
cat > "$TMP/pkg/faultynil/faultynil_test.bn" <<'EOF'
package "pkg/faultynil"

import "pkg/builtins/testing"

type Node struct {
	val int
}

// Reads a field through a nil managed pointer.  Under `bni --test` (nil-checking
// on) this is a recoverable VM fault the runner must report as a FAILURE and
// keep going; without the --test EmitNilChecks wiring it would SEGV the runner.
func TestNilDeref() testing.TestResult {
	var p @Node = nil
	println(p.val)
	return ""
}

// A plain passing test, discovered AFTER TestNilDeref, to prove the runner kept
// running past the fault.
func TestGood() testing.TestResult {
	return ""
}
EOF

# ----- Run `bni --test pkg/faultynil` and assert. -----
out=$("$BNI_BIN" --test \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    -I "$TMP" -L "$TMP" \
    pkg/faultynil 2>&1)
ec=$?

fail=0
if ! printf '%s' "$out" | grep -q "FAIL: TestNilDeref"; then
    echo "FAIL: a nil-deref test must be reported '--- FAIL: TestNilDeref'"
    fail=1
fi
if ! printf '%s' "$out" | grep -q "nil pointer dereference"; then
    echo "FAIL: the fault's 'nil pointer dereference' message must be reported (--test must enable nil-checks)"
    fail=1
fi
if ! printf '%s' "$out" | grep -q "PASS: TestGood"; then
    echo "FAIL: the runner must keep going after the fault (TestGood should still run + pass)"
    fail=1
fi
if [ "$ec" -eq 0 ]; then
    echo "FAIL: a run with a failing test must exit non-zero (got exit 0)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "--- bni --test output was:"
    printf '%s\n' "$out" | sed 's/^/    /'
    exit 1
fi

echo "PASS: bni --test enables nil-checks — a nil-deref Test is reported FAILED and the runner survives"
exit 0
