#!/bin/sh
# e2e/repl.sh — End-to-end test for `bni --repl` (Tier 1 PoC).
#
# Builds bni via boot-comp (cmd/bni isn't bootstrap-runnable since
# pkg/vm uses floats), creates a tiny fixture module that defines a
# `helper` function, then drives the REPL via piped stdin and
# compares output byte-for-byte against expectations.
#
# Covers Tier 1 PoC behaviors:
#   - bare-statement evaluation against the loaded module's scope
#     (calling a func defined in the loaded file)
#   - multi-statement single-line input (locals visible across
#     semicolon-separated stmts in the same turn)
#   - error recovery: an undefined-name error is reported and the
#     session continues working on the next turn
#
# Exit 0 on full pass; non-zero with per-case diagnostics on
# failure.

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

TMP="$(mktemp -d /tmp/binate_e2e_repl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"
FIXTURE="$TMP/fixture.bn"

# ----- Build bni via boot-comp -----
echo "Building bni via boot-comp..."
build_log=$(cd "$BOOTSTRAP_DIR" && go run . -root "$BINATE_DIR" \
    "$BINATE_DIR/cmd/bnc" -- \
    --root "$BINATE_DIR" --build-dir "$BUILD_DIR" \
    -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1)
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: bni build failed:"
    echo "$build_log"
    exit 1
fi
echo "Built: $BNI_BIN"

# ----- Fixture: tiny module with a callable helper. -----
cat > "$FIXTURE" <<'EOF'
package "main"

func helper(x int) int {
    return x * 2
}

func main() {
    // Unused — REPL never invokes main.  Defined to satisfy the
    // loader's expectation of a main entry point.
    println(helper(0))
}
EOF

PASSES=0
FAILS=0
FAIL_NAMES=""

# Run a REPL session with `input` piped on stdin, compare combined
# stdout+stderr against `expected` (exact match including trailing
# newlines and prompt spaces).
run_repl() {
    label="$1"
    input="$2"
    expected="$3"
    actual=$(printf '%s' "$input" | "$BNI_BIN" --repl --root "$BINATE_DIR" "$FIXTURE" 2>&1)
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected:"
        printf '%s\n' "$expected" | sed 's/^/    /'
        echo "  actual:"
        printf '%s\n' "$actual" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# Banner + trailing prompt are constant across cases.  REPL emits
# "> " before each line read; on EOF it prints a final newline and
# exits, so every transcript ends with `> \n`.
BANNER="Binate REPL (Tier 1 PoC). Ctrl-D to exit."

# --- Case 1: basic call into the loaded module. ---
run_repl "basic-call" \
"println(helper(7))
" \
"$BANNER
> 14
> "

# --- Case 2: multi-statement single-line input.  Locals (declared
# via short-var `:=`) are visible to later stmts in the same turn.
# Note: a leading `var` would route to the Tier 2 decl path (which
# errors "first cut") rather than the stmt-list path; short-var
# stays on the stmt path. ---
run_repl "multi-stmt" \
"x := 5; x = x + 10; println(x)
" \
"$BANNER
> 15
> "

# --- Case 3: error recovery.  An undefined-name error is reported
# and the next turn still works against the loaded module. ---
run_repl "error-recovery" \
"undefined_name
println(helper(3))
" \
"$BANNER
> undefined: undefined_name
> 6
> "

# --- Case 4: multi-line input.  Lines accumulate while brace
# depth is positive; continuation prompt is `... `; evaluation
# fires once `}` closes the block.  Output of the loop body
# concatenates onto the same prompt line as the leading `... `s. ---
run_repl "multi-line-for" \
"for i := 0; i < 3; i++ {
println(helper(i))
}
" \
"$BANNER
> ... ... 0
2
4
> "

# --- Case 5: braces inside a string literal must NOT trigger
# multi-line accumulation.  This input is one balanced line. ---
run_repl "braces-in-string" \
'println("hello {world}")
' \
"$BANNER
> hello {world}
> "

# --- Case 6 (Tier 2): top-level `func` decl typed at the prompt
# persists, and a subsequent turn can call it. ---
run_repl "tier2-func-persists" \
"func double(x int) int { return x * 2 }
println(double(7))
" \
"$BANNER
> > 14
> "

# --- Case 7 (Tier 2): two prompt-defined funcs where the second
# calls the first.  Verifies cross-decl call resolution works for
# REPL-introduced VMFuncs (not just for funcs from the loaded
# module). ---
run_repl "tier2-cross-decl-call" \
"func a(x int) int { return x + 1 }
func b(x int) int { return a(x) * 10 }
println(b(4))
" \
"$BANNER
> > > 50
> "

# --- Case 8 (Tier 2): type / var / const decls aren't yet
# supported.  GenDecl surfaces a clear diagnostic and the session
# stays usable. ---
run_repl "tier2-type-rejected" \
"type T struct { X int }
println(helper(7))
" \
"$BANNER
> only func declarations are supported at the prompt (Tier 2 first cut)
> 14
> "

# --- Case 9 (Tier 2): a func decl with a body type error reports
# the error and does NOT register the symbol.  A subsequent turn
# is unaffected: helpers from the loaded module still work. ---
run_repl "tier2-bad-body-recovery" \
"func bad() bool { return 1 }
println(helper(11))
" \
"$BANNER
> cannot assign untyped int to bool
> 22
> "

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
