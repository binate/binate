#!/bin/sh
# e2e/native-opt-loop.sh — End-to-end test that a `--backend native` program
# built at -O1 / -O2 runs a loop to completion instead of hanging.
#
# A loop-carried value (e.g. a loop counter `i` updated `i = i + 1`) is live
# across the loop's back-edge, so it flows between the body and the header blocks
# through its spill SLOT (each native block starts with a fresh regmap; cross-
# block values are stored/reloaded).  The aarch64 lazy-spill dead-store
# elimination emitted the block-live-out spill AFTER the block's terminator
# branch — dead on the taken path, and wholly unreachable after an unconditional
# back-edge — so the counter's updated value never reached its slot and the
# header reloaded the stale value forever: an infinite loop.  This only surfaced
# at -O1+ (mem2reg makes the counter a register-resident SSA value that gets
# spilled at the block boundary); -O0 keeps every local in memory, so the store
# was already eager and correctly placed.  Conformance runs native only at -O0,
# so nothing exercised this until now — a `func main` doing ANY loop (including
# the environment scan in pkg/builtins/startup, which runs before main) hung at
# startup under `--backend native -O1`.
#
# The program below sums 0..99 (= 4950) in an explicit loop and prints it; a
# misplaced counter store either hangs (counter never advances) or prints a wrong
# sum.  Checked on native -O1 and -O2 (the regression) with an LLVM -O1 control
# (the two backends must agree) and a native -O0 control.  Each run is bounded by
# a timeout so a hang is a FAIL, not a stuck test.  The native variants self-skip
# if the host's native backend can't build this program.
#
# Uses a gen1 bnc built from current source.  Auto-discovered by the e2e runner;
# no C compiler required.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_noptloop.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }
fail() {
    echo "FAIL: $1"
    FAIL_NAMES="$FAIL_NAMES ${1%% *}"
    shift
    for line in "$@"; do echo "  $line"; done
    FAILS=$((FAILS + 1))
}

summary() {
    echo ""
    echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
    if [ "$FAILS" -ne 0 ]; then
        echo "Failed:$FAIL_NAMES"
        exit 1
    fi
    exit 0
}

WANT="4950"

# run_timed <seconds> <cmd...> — run a command with a wall-clock bound (portable:
# perl's alarm, available on macOS + Linux).  Exits 142 (128 + SIGALRM) on
# timeout, which the callers treat as a hang.
run_timed() {
    secs="$1"; shift
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# --- the Binate program: an explicit loop with a loop-carried counter ------
cat > "$TMP/main.bn" <<'EOF'
package "main"
import "pkg/builtins/testing"

func main() {
	var sum int = 0
	var i int = 0
	for i < 100 {
		sum = sum + i
		i = i + 1
	}
	testing.Println(sum)
}
EOF

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    fail "gen1 bnc build failed" "$(echo "$gen1_log" | tail -5)"
    summary
fi

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# check_variant <label> <extra-bnc-flags> <required>
#   Build the program with the given flags, run it (bounded by a timeout), and
#   check the printed sum.  required=1 -> a build failure is a hard FAIL (LLVM);
#   required=0 -> a native backend that can't build this program on this host
#   SKIPs (matches the other native e2e tests' self-skip convention).
check_variant() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$(echo "$label" | tr ' /' '__')"
    mkdir -p "$work"
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra --build-dir "$work" \
            -o "$work/run" "$TMP/main.bn" >"$work/comp.log" 2>&1 \
            || [ ! -x "$work/run" ]; then
        if [ "$required" -eq 1 ]; then
            fail "$label: compile failed" "$(tail -5 "$work/comp.log")"
        else
            skip "$label: native backend cannot build this program on this host"
        fi
        return
    fi
    got="$(run_timed 10 "$work/run" 2>&1)"; rc=$?
    if [ "$rc" -eq 142 ]; then
        fail "$label: program HUNG (timed out) — loop did not terminate"
        return
    fi
    if [ "$got" = "$WANT" ]; then
        pass "$label: loop ran to completion (sum=$got)"
    else
        fail "$label: wrong result" "got:  $got" "want: $WANT" "rc:   $rc"
    fi
}

check_variant "llvm -O1"        "-O1"                    1
check_variant "native -O0"      "--backend native -O0"  0
check_variant "native -O1"      "--backend native -O1"  0
check_variant "native -O2"      "--backend native -O2"  0

summary
