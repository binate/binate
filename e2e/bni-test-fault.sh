#!/bin/sh
# e2e/bni-test-fault.sh — End-to-end check that `bni --test` reports a Test that
# hits a recoverable VM fault (Plan 2) as a FAILURE and keeps running, rather than
# either crashing the runner (pre-Plan-2) or silently passing (the hole 2b opened:
# an entry-frame fault now unwinds to Status = FAULTED, which the runner must check
# — see cmd/bni/main.bn runTests).
#
# The fixture package has TWO tests: one that indexes out of bounds (faults) and
# one that passes.  A correct runner prints `--- FAIL:` for the faulting one with
# the runtime-error message, `--- PASS:` for the good one (proving it kept going
# after the fault), and exits non-zero.
#
# bni is built via builder-comp (BUILDER -> gen1 -> bni), same as e2e/repl.sh —
# cmd/bni isn't bootstrap-runnable (pkg/binate/vm uses floats).
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_testfault.XXXXXX")"
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

gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
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
    --build-dir "$BUILD_DIR" \
    -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1)
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: bni build failed:"
    echo "$build_log"
    exit 1
fi
echo "Built: $BNI_BIN"

# ----- Fixture: a package with a faulting Test and a passing Test. -----
mkdir -p "$TMP/pkg/faulty"
cat > "$TMP/pkg/faulty/faulty_test.bn" <<'EOF'
package "pkg/faulty"

import "pkg/builtins/testing"

// Indexes out of bounds — a recoverable VM fault.  The runner must report this
// as a FAILURE (not silently pass), and keep going.
func TestBadIndex() testing.TestResult {
	var s @[]int = make_slice(int, 1)
	var y int = s[5]
	return ""
}

// A plain passing test, discovered AFTER TestBadIndex, to prove the runner kept
// running past the fault.
func TestGood() testing.TestResult {
	return ""
}
EOF

# ----- Run `bni --test pkg/faulty` and assert. -----
out=$("$BNI_BIN" --test pkg/faulty \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    -I "$TMP" -L "$TMP" 2>&1)
ec=$?

fail=0
if ! printf '%s' "$out" | grep -q "FAIL: TestBadIndex"; then
    echo "FAIL: a faulting test must be reported '--- FAIL: TestBadIndex'"
    fail=1
fi
if ! printf '%s' "$out" | grep -q "index out of bounds"; then
    echo "FAIL: the fault's runtime-error message must be reported"
    fail=1
fi
if ! printf '%s' "$out" | grep -q "PASS: TestGood"; then
    echo "FAIL: the runner must keep going after a fault (TestGood should still run + pass)"
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

echo "PASS: bni --test reports a recoverable-fault Test as FAILED and survives"
exit 0
