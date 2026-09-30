#!/bin/sh
# e2e/repl.sh — End-to-end test for `bni --repl` (Tier 1 PoC).
#
# Builds bni via builder-comp, creates a tiny fixture module that defines a
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

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_repl.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"
FIXTURE="$TMP/fixture.bn"

# ----- Build bni via BUILDER → gen1 → bni -----
# Two-stage to keep current-source's mangled-symbol literals out of
# the BUILDER's emit shape; gen1 is BUILDER-built (linked against
# the BUILDER's C runtime) but its codegen is CURRENT source's, so
# gen1's bni output uses current literals + the checkout's runtime.
# See scripts/build-bni.sh for the same pattern.
echo "Building bni via builder-comp (BUILDER → gen1 → bni)..."
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

# Stage 1's -I/-L resolve cmd/bnc's builtin + stdlib deps from the
# BUILDER's frozen bundle only (--base "$BUILDER_LIB" --prepend "$BINATE_DIR"):
# the bnc source cone may only use features the BUILDER has, so source copies
# aren't used and there is no fallback (a not-yet-in-BUILDER feature like `same`
# in std/errors would otherwise fail the build).  Full rationale + lockstep:
# scripts/lib/build-compilers.sh build_gen1.
gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR" --prepend "$BINATE_DIR/ifaces/toolchain")" \
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

# ----- Fixture: tiny module with a callable helper plus a
# loaded-module struct type so REPL cases can attach methods
# to it without first declaring a fresh prompt-defined type. ---
cat > "$FIXTURE" <<'EOF'
package "main"

import "pkg/builtins/testing"

type Box struct { V int }

func helper(x int) int {
    return x * 2
}

func main() {
    // Unused — REPL never invokes main.  Defined to satisfy the
    // loader's expectation of a main entry point.
    testing.Println(helper(0))
}
EOF

# ----- Sibling package fixture for Tier 5 (mid-session
# imports) cases.  The main fixture above does NOT import
# pkg/repldemo — that's the whole point: the user types
# `import "pkg/repldemo"` at the prompt and the loader pulls
# it in lazily.  The package lives under $TMP so the test's
# -I/-L paths see it. ---
mkdir -p "$TMP/pkg/repldemo"
cat > "$TMP/pkg/repldemo.bni" <<'EOF'
package "pkg/repldemo"

func Double(x int) int
EOF
cat > "$TMP/pkg/repldemo/repldemo.bn" <<'EOF'
package "pkg/repldemo"

func Double(x int) int {
    return x + x
}
EOF

# ----- Two packages whose names share the last segment `lib`: the local
# single-segment package "lib" and pkg/other/lib.  A prompt import of one must
# rebind `lib` away from the other, and an explicit alias must be honored. ---
mkdir -p "$TMP/lib" "$TMP/pkg/other/lib"
cat > "$TMP/lib.bni" <<'EOF'
package "lib"

type T struct { X int }

const K int = 1000
EOF
cat > "$TMP/lib/lib.bn" <<'EOF'
package "lib"
EOF
cat > "$TMP/pkg/other/lib.bni" <<'EOF'
package "pkg/other/lib"

type T struct {
    A int
    B int
    C int
}

const K int = 7
EOF
cat > "$TMP/pkg/other/lib/lib.bn" <<'EOF'
package "pkg/other/lib"
EOF
OTHERLIB_FIXTURE="$TMP/otherlib_fixture.bn"
cat > "$OTHERLIB_FIXTURE" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/other/lib"

func main() {
    testing.Println(lib.K)
}
EOF
ALIASLIB_FIXTURE="$TMP/aliaslib_fixture.bn"
cat > "$ALIASLIB_FIXTURE" <<'EOF'
package "main"

import "pkg/builtins/testing"
import L "lib"

func main() {
    testing.Println(L.K)
}
EOF

# ----- An impl whose receiver is spelled through the package's own alias of
# another package's type: pkg/aliaslib's `type LS = aliashome.S; impl *LS : Loc`
# is aliashome.S's impl. ---
mkdir -p "$TMP/pkg/aliashome" "$TMP/pkg/aliaslib"
cat > "$TMP/pkg/aliashome.bni" <<'EOF'
package "pkg/aliashome"

type S struct { N int }

func (s *S) Label() int

func MkS(n int) S
EOF
cat > "$TMP/pkg/aliashome/aliashome.bn" <<'EOF'
package "pkg/aliashome"

func (s *S) Label() int { return s.N * 10 }

func MkS(n int) S { return S{N: n} }
EOF
cat > "$TMP/pkg/aliaslib.bni" <<'EOF'
package "pkg/aliaslib"

import "pkg/aliashome"

type LS = aliashome.S

interface Loc {
    Label() int
}

impl *LS : Loc
EOF
cat > "$TMP/pkg/aliaslib/aliaslib.bn" <<'EOF'
package "pkg/aliaslib"
EOF

# ----- A package whose interface names an INDIRECTLY loaded package's generic
# interface as its parent — directly (pkg/gsub → pkg/gbase) and through an
# `expose` forwarder (pkg/gsubf → pkg/gfwd → pkg/gbase). ---
mkdir -p "$TMP/pkg/gbase" "$TMP/pkg/gsub" "$TMP/pkg/gfwd" "$TMP/pkg/gsubf"
cat > "$TMP/pkg/gbase.bni" <<'EOF'
package "pkg/gbase"

interface Base[T any] {
    Get() T
}
EOF
cat > "$TMP/pkg/gbase/gbase.bn" <<'EOF'
package "pkg/gbase"
EOF
cat > "$TMP/pkg/gfwd.bni" <<'EOF'
package "pkg/gfwd"

expose "pkg/gbase"
EOF
cat > "$TMP/pkg/gfwd/gfwd.bn" <<'EOF'
package "pkg/gfwd"
EOF
for sub in gsub gsubf; do
    if [ "$sub" = gsub ]; then dep=gbase; else dep=gfwd; fi
    cat > "$TMP/pkg/$sub.bni" <<EOF
package "pkg/$sub"

import "pkg/$dep"

interface Sub : $dep.Base[int] {
    Extra() int
}

type S struct { v int }

func (s *S) Get() int

func (s *S) Extra() int

impl *S : Sub

func MkS(n int) S
EOF
    cat > "$TMP/pkg/$sub/$sub.bn" <<EOF
package "pkg/$sub"

func (s *S) Get() int { return s.v }

func (s *S) Extra() int { return s.v + 1 }

func MkS(n int) S { return S{v: n} }
EOF
done

# ----- A generic type with a generic-receiver impl of pkg/gbase's generic
# interface: boxing an instantiation at the prompt mints its impl row on the
# session module. ---
mkdir -p "$TMP/pkg/gcur"
cat > "$TMP/pkg/gcur.bni" <<'EOF'
package "pkg/gcur"

import "pkg/gbase"

type Cursor[T any] struct { v T }

func (c *Cursor[T]) Get() T { return c.v }

impl *Cursor[T] : gbase.Base[T]

func MkInt(n int) Cursor[int]
EOF
cat > "$TMP/pkg/gcur/gcur.bn" <<'EOF'
package "pkg/gcur"

func MkInt(n int) Cursor[int] { return Cursor[int]{v: n} }
EOF

# ----- A package exporting a generic function (its body in the .bni). ---
mkdir -p "$TMP/pkg/gfn"
cat > "$TMP/pkg/gfn.bni" <<'EOF'
package "pkg/gfn"

func Pick[T any](x T) T { return x }
EOF
cat > "$TMP/pkg/gfn/gfn.bn" <<'EOF'
package "pkg/gfn"
EOF

# ----- A package that fails type-checking (its interface names an undefined
# generic parent) next to a clean dependency (pkg/gbase) that is lowered. ---
mkdir -p "$TMP/pkg/gbad"
cat > "$TMP/pkg/gbad.bni" <<'EOF'
package "pkg/gbad"

import "pkg/gbase"

interface Bad : gbase.Nope[int] {
    X() int
}
EOF
cat > "$TMP/pkg/gbad/gbad.bn" <<'EOF'
package "pkg/gbad"
EOF

# ----- pkg/gbaddep imports the failing pkg/gbad; pkg/xa/x and pkg/xb/x share
# the short name `x`, and pkg/xb/x fails type-checking. ---
mkdir -p "$TMP/pkg/gbaddep" "$TMP/pkg/xa/x" "$TMP/pkg/xb/x"
cat > "$TMP/pkg/gbaddep.bni" <<'EOF'
package "pkg/gbaddep"

import "pkg/gbad"

func G() int
EOF
cat > "$TMP/pkg/gbaddep/gbaddep.bn" <<'EOF'
package "pkg/gbaddep"

func G() int { return 1 }
EOF
cat > "$TMP/pkg/xa/x.bni" <<'EOF'
package "pkg/xa/x"

func G(n int) int
EOF
cat > "$TMP/pkg/xa/x/x.bn" <<'EOF'
package "pkg/xa/x"

func G(n int) int { return n + 100 }
EOF
cat > "$TMP/pkg/xb/x.bni" <<'EOF'
package "pkg/xb/x"

func G(a int, b int) int

func F() int
EOF
cat > "$TMP/pkg/xb/x/x.bn" <<'EOF'
package "pkg/xb/x"

func G(a int, b int) int { return a + b }

func F() int { return "not an int" }
EOF

# ----- Bad fixture: a module with a setup-time type error (a
# top-level var whose initializer references an undefined name).
# NewReplSession surfaces this as a ReplError VALUE that the CLI
# shell prints and exits on, BEFORE the banner — see the
# setup-type-error case below. ---
BAD_FIXTURE="$TMP/bad_fixture.bn"
cat > "$BAD_FIXTURE" <<'EOF'
package "main"

import "pkg/builtins/testing"

var bad int = undefinedThing

func main() {
    testing.Println(bad)
}
EOF

# ----- No-`testing` fixture: it does NOT import pkg/builtins/testing, so a
# prompt `import "pkg/builtins/testing"` is a genuine FIRST-time mid-session
# import of that injected package (exercises RegisterImportFuncSigs — the
# prompt then knows testing.Println is `...*any` variadic). ---
NOTESTING_FIXTURE="$TMP/notesting_fixture.bn"
cat > "$NOTESTING_FIXTURE" <<'EOF'
package "main"

func helper(x int) int {
    return x * 2
}

func main() {
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
    fixture="${4:-$FIXTURE}"
    actual=$(printf '%s' "$input" | "$BNI_BIN" --repl \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
        -I "$TMP" -L "$TMP" \
        -main-file "$fixture" 2>&1)
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

# run_repl_setup_error runs the REPL against a fixture with a setup-time
# error.  Stage 2 makes NewReplSession return such errors as VALUES; the
# CLI shell prints them and exits non-zero BEFORE the banner.  Assert the
# error fragment appears, the banner does NOT (proving the prompt was
# never reached), and the exit status is non-zero.  (loadBuiltinBNIs
# reads .bni files from disk, so this path can't be reached from a unit
# test — e2e is its home.)
run_repl_setup_error() {
    label="$1"
    fixture="$2"
    expect_fragment="$3"
    actual=$(printf '' | "$BNI_BIN" --repl \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
        -I "$TMP" -L "$TMP" \
        -main-file "$fixture" 2>&1)
    ec=$?
    if printf '%s' "$actual" | grep -qF "$expect_fragment" \
            && ! printf '%s' "$actual" | grep -qF "$BANNER" \
            && [ "$ec" -ne 0 ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label (exit=$ec)"
        echo "  expected: output contains '$expect_fragment', no banner, nonzero exit"
        echo "  actual:"
        printf '%s\n' "$actual" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# run_repl_import_rejected drives a mid-session `import` of a package the VM
# cannot interpret (a __c_call package like pkg/std/os).  The import must surface
# the clean frontend type error (err_fragment) WITHOUT aborting the session — a
# follow-up turn still evaluates (survive_fragment).  Fragment-based (not exact)
# because the error enumerates every os __c_call site with absolute .bn paths.
run_repl_import_rejected() {
    label="$1"
    input="$2"
    err_fragment="$3"
    survive_fragment="$4"
    actual=$(printf '%s' "$input" | "$BNI_BIN" --repl \
        -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
        -I "$TMP" -L "$TMP" \
        -main-file "$FIXTURE" 2>&1)
    if printf '%s' "$actual" | grep -qF "$err_fragment" \
            && printf '%s' "$actual" | grep -qF "$survive_fragment"; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected: output contains '$err_fragment' AND '$survive_fragment'"
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
"testing.Println(helper(7))
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
"x := 5; x = x + 10; testing.Println(x)
" \
"$BANNER
> 15
> "

# --- Case 3: error recovery.  An undefined-name error is reported
# and the next turn still works against the loaded module. ---
run_repl "error-recovery" \
"undefined_name
testing.Println(helper(3))
" \
"$BANNER
> <repl>:1:1: undefined: undefined_name
> 6
> "

# --- Case 4: multi-line input.  Lines accumulate while brace
# depth is positive; continuation prompt is `... `; evaluation
# fires once `}` closes the block.  Output of the loop body
# concatenates onto the same prompt line as the leading `... `s. ---
run_repl "multi-line-for" \
"for i := 0; i < 3; i++ {
testing.Println(helper(i))
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
'testing.Println("hello {world}")
' \
"$BANNER
> hello {world}
> "

# --- Case 6 (Tier 2): top-level `func` decl typed at the prompt
# persists, and a subsequent turn can call it. ---
run_repl "tier2-func-persists" \
"func double(x int) int { return x * 2 }
testing.Println(double(7))
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
testing.Println(b(4))
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
testing.Println(p.X + p.Y)
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
testing.Println(b.items[0] + b.items[1] + b.items[2])
" \
"$BANNER
> > > > > 60
> "

# --- Case 8a2 (Tier 2): a top-level var initialized with a raw-slice
# literal keeps its elements: the literal's backing is a hidden module
# global (materialized before the var-init synthetic runs), not a slot on
# that one-shot function's stack — plain and managed elements alike, read
# after a later prompt entry has reused the stack. ---
run_repl "tier2-var-raw-slice-literal" \
"type Cell struct { b @int }
var gb *[]readonly Cell = *[]readonly Cell{Cell{b: box(5)}, Cell{b: box(6)}}
var g *[]readonly int = *[]readonly int{1, 2, 3}
var a [64]int = [64]int{9, 9, 9, 9}
testing.Println(g[0], g[1], g[2], *gb[0].b, *gb[1].b)
" \
"$BANNER
> > > > > 1 2 3 5 6
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
testing.Println(k.Get())
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
testing.Println(b.Doubled())
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
testing.Println(t)
" \
"$BANNER
> > > > 100
> "

# --- Case 9 (Tier 2): a func decl with a body type error reports
# the error and does NOT register the symbol.  A subsequent turn
# is unaffected: helpers from the loaded module still work. ---
run_repl "tier2-bad-body-recovery" \
"func bad() bool { return 1 }
testing.Println(helper(11))
" \
"$BANNER
> <repl>:1:26: cannot assign untyped int to bool
> 22
> "

# --- Case 10 (Tier 2 const): single typed const persists and is
# usable from a subsequent stmt-list turn. ---
run_repl "tier2-const-typed" \
"const K int = 42
testing.Println(K)
" \
"$BANNER
> > 42
> "

# --- Case 11 (Tier 2 const): single untyped const persists and
# is usable in arithmetic combined with a later untyped const. ---
run_repl "tier2-const-untyped" \
"const A = 7
const B = 35
testing.Println(A + B)
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
testing.Println(A); testing.Println(B)
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
testing.Println(tripled(11))
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
testing.Println(A); testing.Println(B)
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
testing.Println(x)
x = 42
testing.Println(x)
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
testing.Println(a); testing.Println(b)
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
testing.Println(counter)
" \
"$BANNER
> > > > 3
> "

# --- Case 17 (Tier 2 var-untyped): `var x = expr` infers the type
# from the initializer — a literal (int / bool / char-slice / etc.)
# or any other expression (`var x = i + 100` is an int), and a
# composite literal gives the struct type itself. ---
run_repl "tier2-var-untyped" \
"var i = 7
var s = \"hi\"
testing.Println(i)
testing.Println(s)
var x = i + 100
testing.Println(x)
var b = Box{V: 5}
testing.Println(b.V + helper(7))
" \
"$BANNER
> > > 7
> hi
> > 107
> > 19
> "

# --- Case 18 (Tier 4 redef): redefining a func with the same
# signature replaces the old body.  The fixture's `helper` is
# x*2; the new one is x*3.  Subsequent calls hit the new body. ---
run_repl "tier4-redef-replace" \
"testing.Println(helper(7))
func helper(x int) int { return x * 3 }
testing.Println(helper(7))
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
testing.Println(caller())
func helper(x int) int { return x * 5 }
testing.Println(caller())
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
testing.Println(caller())
func helper(a int, b int) int { return a + b }
testing.Println(caller())
testing.Println(helper(3, 4))
" \
"$BANNER
> > 10
> warning: helper shadowed (incompatible signature); existing callers retain old definition
> 10
> 7
> "

# --- Case 21 (Tier 3 forward refs): a func decl whose body
# references an undefined name parks rather than erroring.
# When the missing dep arrives, the parked func is auto-
# resolved and lowered.  Subsequent calls work normally. ---
run_repl "tier3-forward-ref" \
"func f() int { return g() + 1 }
func g() int { return 41 }
testing.Println(f())
" \
"$BANNER
> function f parked (pending: g)
> function f resolved
> 42
> "

# --- Case 22 (Tier 3): chain forward refs (a → b → c), all
# parked, all resolve when c arrives — dependencies first. ---
run_repl "tier3-forward-ref-chain" \
"func a() int { return b() + 1 }
func b() int { return c() + 10 }
func c() int { return 100 }
testing.Println(a())
" \
"$BANNER
> function a parked (pending: b)
> function b parked (pending: c)
> function b resolved
function a resolved
> 111
> "

# --- Case 23 (Tier 3): calling a still-parked func surfaces
# a clean type-checker error (rather than letting the runtime
# hit \"extern not found\"). ---
run_repl "tier3-pending-use-site-error" \
"func f() int { return g() }
testing.Println(f())
testing.Println(helper(7))
" \
"$BANNER
> function f parked (pending: g)
> <repl>:1:17: function f is unresolved (pending: g)
> 14
> "

# --- Case 24 (Tier 4 method redef): redefining a method with
# the same signature replaces the old body.  Same property as
# the free-func replace path, keyed on the qualified
# <pkg>.<TypeName>.<Method> name.  Subsequent calls hit the new
# body. ---
# --- A function literal in a prompt function: the function's body is
# the last function generating it appends (after the literal), and both
# are lowered. ---
run_repl "tier2-func-literal-in-prompt-func" \
"func k() int { var f @func(int) int = func(x int) int { return x + 1 }; return f(5) }
testing.Println(k())
" \
"$BANNER
> > 6
> "

# --- A redefinition with a different signature shadows the old one; a
# function literal in it that calls the function calls the NEW one (it is
# lowered after the shadow re-points the name). ---
run_repl "tier4-shadow-literal-calls-new" \
"func k() int { return 7 }
func k(n int) int { var f @func(int) int = func(x int) int { if x <= 0 { return 100 }; return k(x - 1) }; return f(n) }
testing.Println(k(3))
" \
"$BANNER
> > warning: k shadowed (incompatible signature); existing callers retain old definition
> 100
> "

run_repl "tier4-method-redef-replace" \
"type Counter struct { n int }
func (c *Counter) Inc() { c.n = c.n + 1 }
var k Counter
k.Inc(); k.Inc()
testing.Println(k.n)
func (c *Counter) Inc() { c.n = c.n + 10 }
k.Inc()
testing.Println(k.n)
" \
"$BANNER
> > > > > 2
> > > 12
> "

# --- Case 25 (Tier 4 method redef): redefining a method with
# a DIFFERENT signature shadows.  Old callers retain the old
# shape via their eager-filled CallCache; fresh calls route
# through the new sig.  Warning prints with the qualified
# Type.Method name. ---
run_repl "tier4-method-shadow-diff-sig" \
"type Counter struct { n int }
func (c *Counter) Add() { c.n = c.n + 1 }
var k Counter
k.Add()
testing.Println(k.n)
func (c *Counter) Add(amt int) { c.n = c.n + amt }
k.Add(7)
testing.Println(k.n)
" \
"$BANNER
> > > > > 1
> warning: Counter.Add shadowed (incompatible signature); existing callers retain old definition
> > 8
> "

# --- Case 26 (Tier 2 body-introduced shape): a prompt-typed
# func body introduces a managed-aggregate shape with a
# DESTRUCTIBLE element type — `@[]@Box`, where Box is the loaded
# fixture struct.  The element `@Box` is a managed pointer and
# requires RefDec at slice-free time, so `__dtor_ms_mp_Box` must
# exist; the loaded module never uses this shape so the helper
# is missing without EnsureReplBodyHelpers.  Before the drain
# fix the func's end-of-statement cleanup hit a missing extern;
# after, the helper is emitted and lowered before the body. ---
run_repl "tier2-body-introduces-managed-slice-of-managed-ptr" \
"func g() { var s @[]@Box = make_slice(@Box, 2); testing.Println(len(s)) }
g()
" \
"$BANNER
> > 2
> "

# --- Case 27 (Tier 2 body-introduced shape, stmt-list path):
# same shape, but typed as a bare statement list at the prompt
# (short-var `:=` keeps the parser on the stmt-list path; a
# leading `var` would route to the decl path instead).  Verifies
# the drain runs on the evalReplStmtList synthetic too. ---
run_repl "tier2-body-stmt-list-managed-slice-of-managed-ptr" \
"s := make_slice(@Box, 3); testing.Println(len(s))
" \
"$BANNER
> 3
> "

# --- Case 28 (Tier 2 body-introduced shape, var-init path):
# var-initializer evaluation runs through runReplVarInit's
# synthetic.  A managed-slice-of-managed-ptr initializer
# registers a pending dtor; the drain emits the helper before
# the synthetic is lowered.  Read-back through a subsequent
# bare-stmt testing.Println. ---
run_repl "tier2-body-var-init-managed-slice-of-managed-ptr" \
"var t @[]@Box = make_slice(@Box, 4)
testing.Println(len(t))
" \
"$BANNER
> > 4
> "

# --- Case 29 (Tier 2 + Tier 3 interaction): a parked func
# whose body introduces a new managed-aggregate shape works
# end-to-end when the missing name arrives.  retryPending's
# IR-gen registers the new shape's dtor in pendingMsDtors;
# retryPending's drain emits the helper before f is lowered,
# so its eager CallCache fills the helper slot directly.
# (Note: even without retryPending's drain, the test would
# pass — the next prompt entry's drain plus
# backfillExternCachesForName would upgrade f's -1 cache
# slot.  Keeping the drain in retryPending is an optimization
# + consistency win, not a sole correctness fix.) ---
run_repl "tier3-body-introduced-shape-via-retry" \
"func f() { var s @[]@Box = make_slice(@Box, 2); h(); testing.Println(len(s)) }
func h() {}
f()
" \
"$BANNER
> function f parked (pending: h)
> function f resolved
> 2
> "

# --- Case 30 (Tier 2 method body-introduced shape): a method
# whose body introduces a new managed-aggregate shape goes
# through evalReplDecl's DECL_FUNC drain just like a free
# func.  Verifies the drain runs on the genMethod IR path
# (not just genFunc) — the call site is the same, the IR-
# gen routine is different. ---
run_repl "tier2-method-body-introduced-shape" \
"func (b *Box) Reset() { var s @[]@Box = make_slice(@Box, 2); b.V = len(s) }
var k Box
k.Reset()
testing.Println(k.V)
" \
"$BANNER
> > > > 2
> "

# --- Case 31 (Stage 1 of pending-non-func): a typed var
# whose initializer references an undefined name parks
# rather than erroring.  Subsequent definition of the
# missing name resolves the var; its initializer runs
# (via runReplVarInit's synthetic in retryPending) and
# the value is observable on next read. ---
run_repl "tier3-pending-var-resolves" \
"var x int = g() + 1
func g() int { return 41 }
testing.Println(x)
" \
"$BANNER
> variable x parked (pending: g)
> variable x resolved
> 42
> "

# --- Ordering pin: a parked var whose initializer PRINTS, resolved in ONE
# turn.  Since the Inc 1 Kernel reshape, notices are returned as Result data
# and rendered AFTER a turn's evaluated-code output (vs. the old immediate
# sink) — so the "resolved" notice now prints AFTER the initializer's "7", not
# before.  Pins that accepted ordering (plan-repl-kernel.md, notices-as-data
# Decision #3); a future edit that reverts the order reddens here. ---
run_repl "kernel-notice-renders-after-eval-output" \
"var x int = f()
func f() int { testing.Println(7); return 41 }
" \
"$BANNER
> variable x parked (pending: f)
> 7
variable x resolved
> "

# --- Case 32 (Stage 1): a typed const whose value expression
# references an undefined name parks; defining the missing
# name resolves it.  Consts are folded at IR-gen time so
# retryPending only re-runs GenDecl (no synthetic, no slot
# materialization). ---
run_repl "tier3-pending-const-resolves" \
"const N int = M + 1
const M int = 41
testing.Println(N)
" \
"$BANNER
> constant N parked (pending: M)
> constant N resolved
> 42
> "

# --- Case 33 (Stage 1): reading a still-pending var from
# non-tentative code surfaces a clean "variable x is
# unresolved" type-checker error.  Mirrors the pending-func
# use-site error case from the Tier 3 first cut. ---
run_repl "tier3-pending-var-use-site-error" \
"var x int = g() + 1
testing.Println(x)
" \
"$BANNER
> variable x parked (pending: g)
> <repl>:1:17: variable x is unresolved (pending: g)
> "

# --- Case 34 (Stage 1 (c) — per-member group parking):
# a const group with one member whose value references an
# undefined name parks ONLY that member (groups are syntactic
# sugar with no semantic effect).  A's clean value lands
# immediately; B parks alone with its iota position preserved
# (so retry computes B = M + iota_at_position).  Defining M
# resolves B independently. ---
run_repl "tier3-pending-const-group-resolves" \
"const (
A int = 1
B int = M + 1
)
const M int = 40
testing.Println(A); testing.Println(B)
" \
"$BANNER
> ... ... ... constant B parked (pending: M)
> constant B resolved
> 1
41
> "

# --- Case 35 (Stage 1 (c)): iota position is preserved across
# parking.  In `const (A=iota; B=M+iota; C=iota)`, B parks at
# position 1 with iota=1 recorded.  A's iota=0 and C's iota=2
# land immediately.  When M=10 arrives, B's retry uses
# iota=1, giving B = 10 + 1 = 11 (not 10 + 0 = 10).  This
# verifies parkPendingDeclMember + RetryPendingDecls iota
# restoration + GenConstMember's positional iota correctness
# end-to-end. ---
run_repl "tier3-pending-const-group-iota-positional" \
"const (
A int = iota
B int = M + iota
C int = iota
)
const M int = 10
testing.Println(A); testing.Println(B); testing.Println(C)
" \
"$BANNER
> ... ... ... ... constant B parked (pending: M)
> constant B resolved
> 0
11
2
> "

# --- Case 36 (Stage 2 (b) of plan-repl-tier3-pending-types.md):
# a struct type whose field type references an undefined name
# parks rather than erroring.  When the missing type arrives,
# the parked type is auto-resolved.  After resolution a var of
# that type works end-to-end. ---
run_repl "tier3-pending-struct-type-resolves" \
"type T struct { F Bag }
type Bag struct { N int }
var x T
x.F.N = 42
testing.Println(x.F.N)
" \
"$BANNER
> type T parked (pending: Bag)
> type T resolved
> > > 42
> "

# --- Case 37 (Stage 2 (c): use-site propagation): a var of a
# pending type propagates the pending dependency — the var
# itself parks.  Resolving the pending type also resolves the
# parked var. ---
run_repl "tier3-pending-type-use-site-propagates" \
"type T struct { F Bag }
var x T
type Bag struct { N int }
testing.Println(\"resolved\")
" \
"$BANNER
> type T parked (pending: Bag)
> variable x parked (pending: T)
> type T resolved
variable x resolved
> resolved
> "

# --- Case 38 (Stage 2 (d): alias forward-ref): `type R = X`
# where X is undefined parks the alias.  Defining X resolves
# it.  Mirrors the struct-type parking flow for the alias
# branch of collectTypeDecl. ---
run_repl "tier3-pending-alias-resolves" \
"type R = Bag
type Bag struct { N int }
var x R
x.N = 7
testing.Println(x.N)
" \
"$BANNER
> type R parked (pending: Bag)
> type R resolved
> > > 7
> "

# --- Case 39 (Stage 2 (d): named-non-struct forward-ref):
# `type C Heat` where Heat is undefined parks; defining Heat
# resolves it.  Covers the named-non-struct branch of
# collectTypeDecl. ---
run_repl "tier3-pending-named-nonstruct-resolves" \
"type Celsius Heat
type Heat int
var t Celsius
testing.Println(t)
" \
"$BANNER
> type Celsius parked (pending: Heat)
> type Celsius resolved
> > 0
> "

# --- Case 40: a pointer to a parked type parks too — a parked
# declaration binds nothing, so `var p *T` waits for T — and
# resolves after it. ---
run_repl "tier3-pending-type-pointer-use-parks" \
"type T struct { F Bag }
var p *T
type Bag struct { N int }
testing.Println(\"reached\")
" \
"$BANNER
> type T parked (pending: Bag)
> variable p parked (pending: T)
> type T resolved
variable p resolved
> reached
> "

# --- Case 41: mutual recursion via managed pointers.  `type A
# struct { Next @B }` parks waiting on B; `type B struct { Next @A }`
# parks waiting on A; the two resolve together at that prompt. ---
run_repl "tier3-pending-mutual-recursion-resolves" \
"type A struct { Next @B }
type B struct { Next @A }
testing.Println(\"resolved\")
" \
"$BANNER
> type A parked (pending: B)
> type B parked (pending: A)
type A resolved
type B resolved
> resolved
> "

# --- Case 42: a function whose signature names a parked type
# parks on it.  T parks (waiting on Bag); `func f(x T) int`
# parks waiting on T.  When Bag arrives, T resolves, then f. ---
run_repl "tier3-pending-func-sig-parks-func" \
"type T struct { F Bag }
func f(x T) int { return 0 }
type Bag struct { N int }
testing.Println(\"done\")
" \
"$BANNER
> type T parked (pending: Bag)
> function f parked (pending: T)
> type T resolved
function f resolved
> done
> "

# --- Case 43: a method on a parked type parks.  T parks
# (waiting on Bag); a method on *T parks waiting on T.  When
# Bag arrives: T resolves, then the method.  After that the
# method is callable. ---
run_repl "tier3-pending-method-on-pending-receiver" \
"type T struct { F Bag }
func (t *T) M() int { return 7 }
type Bag struct { N int }
var x T
testing.Println(x.M())
" \
"$BANNER
> type T parked (pending: Bag)
> method T.M parked (pending: T)
> type T resolved
method T.M resolved
> > 7
> "

# --- Case 44: a by-value type cycle.  `type A struct { B B }`
# parks A waiting on B; `type B struct { A A }` parks B waiting
# on A.  The two are checked together, as a file's types are, so
# the by-value cycle is reported, and both stay parked (a
# redefinition that breaks the cycle — e.g. a pointer field —
# replaces the parked one). ---
run_repl "tier3-pending-cycle-detected" \
"type A struct { B B }
type B struct { A A }
" \
"$BANNER
> type A parked (pending: B)
> type B parked (pending: A)
type A still parked (it does not check)
type B still parked (it does not check)
<repl>:1:1: recursive type: a type cannot contain itself by value (hold the recursive field via a pointer -- *T or @T)
> "

# --- Case 45 (Tier 5: mid-session imports).  pkg/repldemo
# isn't imported by the loaded fixture; user types
# `import "pkg/repldemo"` at the prompt and the loader pulls
# it in.  After the load + type-check + lower, subsequent
# prompt entries can call repldemo.Double. ---
# --- A prompt import REBINDS its name: after `import "lib"`, `lib` is the local
# package "lib", not the fixture's pkg/other/lib — its T and K. ---
run_repl "tier5-prompt-import-rebinds-alias" \
"testing.Println(lib.K)
import \"lib\"
var t lib.T = lib.T{X: 8}
testing.Println(t.X)
testing.Println(lib.K)
" \
"$BANNER
> 7
> package lib loaded
> > 8
> 1000
> " "$OTHERLIB_FIXTURE"

# --- A fixture's explicit import alias (`import L "lib"`) resolves at the
# prompt. ---
run_repl "tier1-fixture-explicit-alias" \
"testing.Println(L.K)
" \
"$BANNER
> 1000
> " "$ALIASLIB_FIXTURE"

# --- A mid-session import's impl whose receiver is the package's own alias
# (`impl *LS : Loc`, LS = aliashome.S) keys on aliashome.S — even with a
# same-named `LS` already declared at the prompt. ---
run_repl "tier5-mid-session-alias-receiver-impl" \
"type LS struct { Q int }
import \"pkg/aliashome\"
import \"pkg/aliaslib\"
var s aliashome.S = aliashome.MkS(4)
var l *aliaslib.Loc = &s
testing.Println(l.Label())
" \
"$BANNER
> > package pkg/aliashome loaded
> package pkg/aliaslib loaded
> > > 40
> "

# --- A mid-session import whose interface extends an indirectly loaded
# package's generic interface (directly, and through an `expose` forwarder):
# the parent's methods dispatch. ---
run_repl "tier5-mid-session-indirect-generic-parent" \
"import \"pkg/gsub\"
var s gsub.S = gsub.MkS(7)
var sub *gsub.Sub = &s
testing.Println(sub.Get())
testing.Println(sub.Extra())
" \
"$BANNER
> package pkg/gsub loaded
> > > 7
> 8
> "

# --- Boxing an imported generic type's instantiation into the generic
# interface its generic-receiver impl satisfies: the impl row IR-gen mints
# at the box, and the instantiated method, reach the VM before the prompt
# runs (not "interface vtable not found" / "interface method slot is
# empty"). ---
run_repl "tier5-box-generic-receiver-impl-instantiation" \
"import \"pkg/gcur\"
import \"pkg/gbase\"
var c gcur.Cursor[int] = gcur.MkInt(5)
var bb *gbase.Base[int] = &c
testing.Println(bb.Get())
" \
"$BANNER
> package pkg/gcur loaded
> package pkg/gbase loaded
> > > 5
> "

# --- Functions IR-gen appends while generating a prompt entry are lowered
# with it: a generic type's instantiated method used in a prompt function,
# and an imported generic function called from a statement, a function
# and a variable initializer (each panicked "extern not found"). ---
run_repl "tier5-generic-instantiation-in-prompt-func" \
"import \"pkg/gcur\"
func f() int { var c gcur.Cursor[int] = gcur.MkInt(3); return c.Get() }
testing.Println(f())
" \
"$BANNER
> package pkg/gcur loaded
> > 3
> "

run_repl "tier5-imported-generic-func-at-prompt" \
"import \"pkg/gfn\"
testing.Println(gfn.Pick[int](6))
func q() int { return gfn.Pick[int](7) }
testing.Println(q())
var z int = gfn.Pick[int](8)
testing.Println(z)
" \
"$BANNER
> package pkg/gfn loaded
> 6
> > 7
> > 8
> "

run_repl "tier5-mid-session-indirect-generic-parent-forwarder" \
"import \"pkg/gsubf\"
var s gsubf.S = gsubf.MkS(7)
var sub *gsubf.Sub = &s
testing.Println(sub.Get())
testing.Println(sub.Extra())
" \
"$BANNER
> package pkg/gsubf loaded
> > > 7
> 8
> "

# --- The alias-receiver impl again, with pkg/aliashome loaded only indirectly
# (by pkg/aliaslib's import) before it is imported at the prompt. ---
run_repl "tier5-mid-session-alias-receiver-indirect" \
"import \"pkg/aliaslib\"
import \"pkg/aliashome\"
var s aliashome.S = aliashome.MkS(4)
var l *aliaslib.Loc = &s
testing.Println(l.Label())
" \
"$BANNER
> package pkg/aliaslib loaded
> package pkg/aliashome loaded
> > > 40
> "

# --- Type and var groups at the prompt: each member is declared as if typed on
# its own (a const group stays whole). ---
run_repl "tier2-type-and-var-groups" \
"type ( PS struct { q int }; PA = int )
var p PS
p.q = 3
var ( v1 PA = 5; v2 int = 6 )
testing.Println(p.q + v1 + v2)
" \
"$BANNER
> > > > > 14
> "

run_repl "tier5-mid-session-import-call" \
'import "pkg/repldemo"
testing.Println(repldemo.Double(21))
' \
"$BANNER
> package pkg/repldemo loaded
> 42
> "

# --- Case 46 (Tier 5 import alias): `import alt "pkg/repldemo"`
# binds the package to `alt` rather than the default last-segment
# name.  Calls through the alias work; the default name `repldemo`
# does NOT (would be an undefined identifier).  Verifies the
# alias-bearing branch of evalReplImport. ---
run_repl "tier5-mid-session-import-alias" \
'import alt "pkg/repldemo"
testing.Println(alt.Double(11))
' \
"$BANNER
> package pkg/repldemo loaded
> 22
> "

# --- Case 47 (Tier 5 re-import idempotence): importing the same
# package twice in a session is a no-op on the second attempt —
# replProcessedPkgs.containsPath skips re-processing.  The
# session scope still has the alias defined, so the call works.
# ---
run_repl "tier5-mid-session-reimport-idempotent" \
'import "pkg/repldemo"
import "pkg/repldemo"
testing.Println(repldemo.Double(5))
' \
"$BANNER
> package pkg/repldemo loaded
> package pkg/repldemo loaded
> 10
> "

# --- Case 47b (Tier 5: a top-level `var` decl AFTER a mid-session import).  The
# import's per-package LowerModule leaves the VM's module-lowering context at the
# imported package; a following `var g` must be qualified under the SESSION module
# (SetModuleContext restores it) — else MaterializeOneGlobal registers the global
# under the import's package while the init synthetic stores under "main", a
# null-address SIGSEGV.  Regression guard for that (pre-existing) crash. testing
# comes from the fixture, so this exercises SetModuleContext independent of the
# prompt-import-of-testing path. ---
run_repl "tier5-var-decl-after-mid-session-import" \
'import "pkg/repldemo"
var g int = 42
testing.Println(g)
' \
"$BANNER
> package pkg/repldemo loaded
> > 42
> "

# --- Case 47c (Tier 5: mid-session import of testing, an injected VARIADIC
# package, then boxing a PROMPT-DEFINED type into it).  Against NOTESTING_FIXTURE
# so `import "pkg/builtins/testing"` is a genuine first-time mid-session import:
# the prompt then knows testing.Println is `...*any` (RegisterImportFuncSigs) and a
# subsequent prompt-defined `type Fahr int` value boxes + prints.  Exercises the
# whole prompt-import-and-use-testing path (adversarial-review repro). ---
run_repl "tier5-mid-session-import-testing-box-prompt-type" \
'import "pkg/builtins/testing"
type Fahr int
var f Fahr
f = 451
testing.Println(f)
' \
"$BANNER
> package pkg/builtins/testing loaded
> > > > 451
> " \
"$NOTESTING_FIXTURE"

# --- Case 47a (Tier 5: mid-session import of a __c_call package is rejected
# cleanly, WITHOUT killing the session).  pkg/std/os uses native-only __c_call,
# which the VM cannot interpret; importing it at the prompt must surface the
# frontend "cannot be interpreted" type error and leave the session alive so a
# follow-up turn still evaluates (helper(7) -> 14).  Regression guard: the
# frontend check records the error on the persisted checker, but the import loop
# must skip lowering the erroring package — else IR-gen's unconditional OP_C_CALL
# reaches lower_instr's default arm and aborts the whole session. ---
# --- A mid-session import that loads a failing package (an undefined generic
# parent) and a clean one: the error is reported, the failing package never
# reaches IR-gen, and the session survives. ---
run_repl_import_rejected "tier5-mid-session-import-bad-generic-parent" \
'import "pkg/gbad"
testing.Println(helper(7))
' \
    "Nope" \
    "14"

# --- A package importing a failed one is not imported either (and says so);
# the session survives. ---
run_repl_import_rejected "tier5-mid-session-import-depends-on-failed" \
'import "pkg/gbad"
import "pkg/gbaddep"
testing.Println(helper(7))
' \
    "failed type-checking): pkg/gbaddep" \
    "14"

# --- An import that fails type-checking does not rebind its alias: `x` still
# names pkg/xa/x, in the checker and in IR-gen alike. ---
run_repl_import_rejected "tier5-mid-session-failed-import-keeps-alias" \
'import "pkg/xa/x"
import "pkg/xb/x"
testing.Println(x.G(3))
' \
    "failed type-checking): pkg/xb/x" \
    "103"

run_repl_import_rejected "tier5-mid-session-import-ccall-rejected" \
'import "pkg/std/os"
testing.Println(helper(7))
' \
    "__c_call cannot be interpreted" \
    "14"

# --- Case 48 (Plan-B B3: REPL parked-member iota-repeat).  B0 = M<<iota
# parks (pending M); the bare B1 repeats B0's M-dependent initializer, so
# it parks too.  When M=2 arrives both resolve, and B1 must be the
# REPEATED value 2<<1 = 4 — NOT the plain iota index 1 (the pre-fix bug).
# Transcript verified by driving a gen1-built bni manually. ---
run_repl "tier3-pending-const-group-bare-iota-repeat" \
"const ( B0 int = M << iota; B1 )
const M int = 2
testing.Println(B1)
" \
"$BANNER
> constant B0 parked (pending: M)
constant B1 parked (pending: M)
> constant B0 resolved
constant B1 resolved
> 4
> "

# --- Case 49: a parked declaration whose missing name arrives with a
# type that does not fit stays parked: its error is shown once, and
# a later declaration that fits resolves it. ---
run_repl "tier3-failed-retry-stays-parked" \
"var x int = y
var y bool = true
var y int = 2
testing.Println(x)
" \
"$BANNER
> variable x parked (pending: y)
> variable x still parked (it does not check)
<repl>:1:13: cannot assign bool to int
> variable x resolved
> 2
> "

# --- Case 50: redefining a type at the prompt is rejected (a type
# is identified by its name, so the old type's values could not
# keep their layout). ---
run_repl "tier4-type-redefinition-rejected" \
"type T struct { a int }
type T struct { b int }
" \
"$BANNER
> > <repl>:1:1: cannot redefine type T
> "

# --- Setup-error case: a type error in the loaded module surfaces
# (Stage 2) as a NewReplSession error VALUE that the CLI shell prints
# and exits on, BEFORE the banner/prompt.  Pins errors-as-values
# end-to-end — unreachable from a unit test since loadBuiltinBNIs
# reads the builtins from disk. ---
run_repl_setup_error "setup-type-error" "$BAD_FIXTURE" \
    "undefined: undefinedThing"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
