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

# ----- Fixture: tiny module with a callable helper plus a
# loaded-module struct type so REPL cases can attach methods
# to it without first declaring a fresh prompt-defined type. ---
cat > "$FIXTURE" <<'EOF'
package "main"

type Box struct { V int }

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

# --- Case 8 (Tier 2): struct-type decl (no managed fields)
# at the prompt registers the type so subsequent var decls
# and field reads work against it. ---
run_repl "tier2-type-struct" \
"type Point struct { X int; Y int }
var p Point
p.X = 10
p.Y = 20
println(p.X + p.Y)
" \
"$BANNER
> > > > > 30
> "

# --- Case 8a (Tier 2): managed-field structs work end-to-end.
# `type T struct { S @[]int }` triggers dedup-aware emission
# of __dtor_T + __copy_T (and the field-type's __dtor_) into
# the module; the REPL driver lowers each new helper. ---
run_repl "tier2-type-managed-field" \
"type Bag struct { items @[]int }
var b Bag
b.items = make_slice(int, 3)
b.items[0] = 10; b.items[1] = 20; b.items[2] = 30
println(b.items[0] + b.items[1] + b.items[2])
" \
"$BANNER
> > > > > 60
> "

# --- Case 8b (Tier 2): methods on a prompt-defined type
# work end-to-end.  Pointer receiver mutates; value receiver
# reads.  Both invoked via the obj.M() selector path. ---
run_repl "tier2-method-on-prompt-type" \
"type Counter struct { n int }
func (c *Counter) Inc() { c.n = c.n + 1 }
func (c Counter) Get() int { return c.n }
var k Counter
k.Inc(); k.Inc(); k.Inc()
println(k.Get())
" \
"$BANNER
> > > > > > 3
> "

# --- Case 8c (Tier 2): methods can also attach to a type
# defined in the loaded module (Box, from the fixture above),
# not just to types declared at the prompt.  The receiver
# resolution path is the same — type checker accepts any
# local named type. ---
run_repl "tier2-method-on-loaded-type" \
"func (b *Box) Doubled() int { return b.V * 2 }
var b Box
b.V = 21
println(b.Doubled())
" \
"$BANNER
> > > > 42
> "

# --- Case 8d (Tier 2): named non-struct type
# (`type Celsius int`).  No new IR-side state needed — the
# type checker owns the symbol via collectTypeDecl; reads
# / writes go through the underlying int. ---
run_repl "tier2-type-named-nonstruct" \
"type Celsius int
var t Celsius
t = 100
println(t)
" \
"$BANNER
> > > > 100
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

# --- Case 10 (Tier 2 const): single typed const persists and is
# usable from a subsequent stmt-list turn. ---
run_repl "tier2-const-typed" \
"const K int = 42
println(K)
" \
"$BANNER
> > 42
> "

# --- Case 11 (Tier 2 const): single untyped const persists and
# is usable in arithmetic combined with a later untyped const. ---
run_repl "tier2-const-untyped" \
"const A = 7
const B = 35
println(A + B)
" \
"$BANNER
> > > 42
> "

# --- Case 12 (Tier 2 const): single-line grouped const block;
# both members register and are usable.  (Multi-line const(...)
# groups would need the brace-depth scanner to track parens too —
# documented PoC limitation.) ---
run_repl "tier2-const-group-inline" \
"const ( A = 10; B = 20 )
println(A); println(B)
" \
"$BANNER
> > 10
20
> "

# --- Case 13 (Tier 2 const): a const can be referenced inside a
# func decl typed at the prompt.  Registration ordering: const
# first, then func, then call. ---
run_repl "tier2-const-then-func" \
"const SCALE int = 3
func tripled(x int) int { return x * SCALE }
println(tripled(11))
" \
"$BANNER
> > > 33
> "

# --- Case 14: multi-line const ( ... ) is recognized as a
# continuation by the paren-aware accumulator (computeOpenDepth
# now tracks `(` / `)` in addition to `{` / `}`).  Each non-final
# input line that leaves depth > 0 yields a `... ` continuation
# prompt; the closing `)` triggers evaluation. ---
run_repl "multi-line-const-group" \
"const (
A = 100
B = 200
)
println(A); println(B)
" \
"$BANNER
> ... ... ... > 100
200
> "

# --- Case 15 (Tier 2 var): a typed var registers a global,
# zero-initialized when no initializer is given.  Reads and
# writes from subsequent prompt entries see the same storage. ---
run_repl "tier2-var-readwrite" \
"var x int
println(x)
x = 42
println(x)
" \
"$BANNER
> > 0
> > 42
> "

# --- Case 15b (Tier 2 var-init): `var x T = expr` at the prompt
# now runs the initializer right after registration, so the
# global has its declared value before the next prompt entry
# sees it.  Inter-decl references work too (b reads a). ---
run_repl "tier2-var-init-eval" \
"var a int = 5
var b int = a * 10 + 1
println(a); println(b)
" \
"$BANNER
> > > 5
51
> "

# --- Case 16 (Tier 2 var): a func defined at the prompt can
# read AND mutate a previously-declared var.  Verifies that the
# func's lowered bytecode wires up to the same global storage
# as bare-expr reads. ---
run_repl "tier2-var-func-mutates" \
"var counter int
func bump() { counter = counter + 1 }
bump(); bump(); bump()
println(counter)
" \
"$BANNER
> > > > 3
> "

# --- Case 17 (Tier 2 var-untyped): `var x = expr` with a literal
# initializer infers the type (int / bool / char-slice / etc.).
# Non-literal initializers like `var x = i + 100` still need an
# explicit type; rejected with a clear diagnostic. ---
run_repl "tier2-var-untyped" \
"var i = 7
var s = \"hi\"
println(i)
println(s)
var x = i + 100
println(helper(7))
" \
"$BANNER
> > > 7
> hi
> var decl at the prompt requires an explicit type or a literal initializer
> 14
> "

# --- Case 18 (Tier 4 redef): redefining a func with the same
# signature replaces the old body.  The fixture's `helper` is
# x*2; the new one is x*3.  Subsequent calls hit the new body. ---
run_repl "tier4-redef-replace" \
"println(helper(7))
func helper(x int) int { return x * 3 }
println(helper(7))
" \
"$BANNER
> 14
> > 21
> "

# --- Case 19 (Tier 4 redef): a previously-defined caller continues
# to work, but its calls now route to the redefined body.  Verifies
# the in-place vm.Funcs rebind keeps cached call indices valid. ---
run_repl "tier4-redef-caller-sees-new" \
"func caller() int { return helper(10) }
println(caller())
func helper(x int) int { return x * 5 }
println(caller())
" \
"$BANNER
> > 20
> > 50
> "

# --- Case 20 (Tier 4 shadow): redefining with a DIFFERENT
# signature now SHADOWS rather than rejects.  The OLD helper stays
# callable through any caller whose CallCache already resolved
# it — they invoke the old shape via the still-live old idx.
# A direct call from a fresh prompt entry (lowered AFTER the
# shadow) routes through the new sig.  The warning surfaces
# explicitly so the user knows it happened. ---
run_repl "tier4-shadow-diff-sig" \
"func caller() int { return helper(5) }
println(caller())
func helper(a int, b int) int { return a + b }
println(caller())
println(helper(3, 4))
" \
"$BANNER
> > 10
> warning: helper shadowed (incompatible signature); existing callers retain old definition
> 10
> 7
> "

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
