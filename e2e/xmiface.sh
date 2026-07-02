#!/bin/sh
# e2e/xmiface.sh — End-to-end test of CROSS-MODE interface-method dispatch:
# a program running under the bytecode VM dispatching interface methods whose
# implementations live in a NATIVELY-compiled package.
#
# This path (dispatchCompiledIfaceMethod in pkg/binate/vm/vm_exec_iface.bn) is
# reachable only when a package is NATIVE-INJECTED into the VM (its @__ivt /
# @__ivtshim vtables registered), which cmd/bni does for pkg/std/* only.  A
# synthetic conformance-test package is instead lowered to bytecode in the VM
# modes, so the untested shapes below cannot be reached from the conformance
# suite (726/577 only reach the native path through stdlib impls, and only with
# pointer receivers / no-arg / scalar-and-slice shapes).  So this test builds a
# custom host that injects a fixture package's `__Package()` descriptor
# alongside StandardPackages(), then runs VM programs that dispatch into it —
# covering the four shapes with no current stdlib impl:
#   (a) a VALUE-receiver interface method (the shim slot holds the iv-dispatch
#       thunk's handle; a0 = the iv-data pointer the thunk derefs);
#   (b) a method with MULTIPLE aggregate args (the a1/a2 by-address slots);
#   (c) a method with a FLOAT arg (the shim's int-slot -> FP bitcast path);
#   (d) the >6 user-arg overflow guard (a negative test — a loud vmPanic, not
#       silent truncation).
#
# The fixture's interface impls run as native machine code (the host links them
# and injects their descriptor); the dispatching main runs as bytecode.  Gen1
# (the current tree's bnc, built by the BUILDER) compiles the host, since the
# host imports pkg/binate/{interp,vm}, which are outside the BUILDER's cone.
#
# Exit 0 on full pass; non-zero with diagnostics on failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

. "$BINATE_DIR/scripts/lib/build-compilers.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_xmiface.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/xmiface" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture package: pkg/xmiface (interface impls, compiled NATIVELY) ----
cat > "$I_ROOT/pkg/xmiface.bni" <<'EOF'
package "pkg/xmiface"

// (a) A VALUE-receiver interface method: the impl's shim-vtable slot holds the
// generated iv-dispatch thunk's handle, and the thunk derefs a0 (the iv-data
// pointer) to recover the receiver value.
interface Doubler {
	Double() int
}
type Wrapper struct {
	V int
}
func (w Wrapper) Double() int
impl Wrapper : Doubler

// (b) A method with MULTIPLE aggregate args: each Pair rides one by-address
// dispatch slot (a1, a2), re-coerced by the native shim.
type Pair struct {
	X int
	Y int
}
interface Combiner {
	Combine(a Pair, b Pair) int
}
type Adder struct {
	Base int
}
func (r *Adder) Combine(a Pair, b Pair) int
impl *Adder : Combiner

// (c) A method with a FLOAT arg: the all-int dispatch slot is bitcast to a
// float register by the shim.
interface Scaler {
	Scale(f float64) int
}
type Mult struct {
	Factor int
}
func (m *Mult) Scale(f float64) int
impl *Mult : Scaler

// (d) A method with >6 user-arg words: cross-mode dispatch must trip the loud
// overflow guard (the shim primitives carry only a0..a6 = receiver + 6 args).
interface Many {
	Sum7(a int, b int, c int, d int, e int, f int, g int) int
}
type Summer struct {
	Tag int
}
func (s *Summer) Sum7(a int, b int, c int, d int, e int, f int, g int) int
impl *Summer : Many

// (e) An interface that EXTENDS another (interface embedding): the impl's concat
// vtable lays the PARENT (Base) sub-block at a NON-ZERO slot offset
// (IfaceParentSlotOffset > 0).  A bytecode main upcasts a native-injected @Ext to
// @Base and dispatches a parent method through that view — so the dispatch reads
// the vtable word ADVANCED by offset*8, an address interior to the registered
// @__ivt.  Exercises the shim-vtable RANGE lookup (an exact-match lookup misses
// the adjusted address and aborts "no shim vtable").
interface Base {
	BaseVal() int
}
interface Ext : Base {
	ExtVal() int
}
type Node struct {
	V int
}
func (n *Node) BaseVal() int
func (n *Node) ExtVal() int
impl *Node : Ext

// (f) A MULTI-LEVEL chain (C1 : B1 : A1): a transitive upcast @C1 -> @A1 places
// A1's sub-block at offset>1 in C1's nested concat vtable, so the cross-mode
// dispatch reads a word advanced by more than one slot — exercising the
// offset-chain arithmetic end-to-end (not just the one-level offset from (e)).
interface A1 {
	AVal() int
}
interface B1 : A1 {
	BVal() int
}
interface C1 : B1 {
	CVal() int
}
type Chain struct {
	V int
}
func (n *Chain) AVal() int
func (n *Chain) BVal() int
func (n *Chain) CVal() int
impl *Chain : C1

// (g) A VALUE-receiver PARENT method dispatched at offset>0: combines the
// iv-dispatch-thunk path (a value receiver's shim slot holds the generated thunk
// handle, which derefs a0 to recover the receiver — case (a)) with the offset>0
// range lookup (case (e)).  The parent method's shim slot is the one the range
// lookup selects at the advanced word, so this proves the thunk resolves through
// the interior mapping, not just a direct handle.
interface VBase {
	VBaseVal() int
}
interface VExt : VBase {
	VExtVal() int
}
type VNode struct {
	V int
}
func (n VNode) VBaseVal() int
func (n VNode) VExtVal() int
impl VNode : VExt
EOF

cat > "$L_ROOT/pkg/xmiface/xmiface.bn" <<'EOF'
package "pkg/xmiface"

func (w Wrapper) Double() int {
	return w.V * 2
}

func (r *Adder) Combine(a Pair, b Pair) int {
	return r.Base + a.X + a.Y + b.X + b.Y
}

func (m *Mult) Scale(f float64) int {
	return cast(int, f) * m.Factor
}

func (s *Summer) Sum7(a int, b int, c int, d int, e int, f int, g int) int {
	return s.Tag + a + b + c + d + e + f + g
}

func (n *Node) BaseVal() int {
	return n.V
}

func (n *Node) ExtVal() int {
	return n.V * 10
}

func (n *Chain) AVal() int {
	return n.V
}

func (n *Chain) BVal() int {
	return n.V * 2
}

func (n *Chain) CVal() int {
	return n.V * 3
}

func (n VNode) VBaseVal() int {
	return n.V
}

func (n VNode) VExtVal() int {
	return n.V * 100
}
EOF

# ---- custom host: cmd/bni's runProgram + fixture in the VM inject-set ----
# Adding xmiface.__Package() to interp.New's package set makes the run path
# skip lowering pkg/xmiface (Interp.isCompiled) and dispatch its interface
# methods natively — the cross-mode path under test.
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/builtins/reflect"
import "pkg/std/errors"
import "pkg/std/os"
import "pkg/bootstrap"
import "pkg/xmiface"

// host <prog.bn> <I-paths colon-sep> <L-paths colon-sep>
func main() {
	var args @[]@[]char = bootstrap.Args()
	if len(args) < 3 {
		println("usage: host <prog.bn> <I-paths> <L-paths>")
		os.Exit(1)
	}
	var src @[]uint8 = readFile(args[0])
	if len(src) == 0 {
		print("host: cannot read ")
		println(args[0])
		os.Exit(1)
	}
	var p @parser.Parser = parser.New(src, args[0])
	var f @ast.File = p.ParseFile()
	var perrs @[]parser.ParseError = p.Errors()
	if len(perrs) > 0 {
		for i := 0; i < len(perrs); i++ { println(perrs[i].Msg) }
		os.Exit(1)
	}
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f

	// Inject-set = the standard library plus the fixture package, so the fixture
	// is treated as native-injected (not lowered) by the run path.
	var std @[]@reflect.Package = interp.StandardPackages()
	var pkgs @[]@reflect.Package = make_slice(@reflect.Package, len(std) + 1)
	for i := 0; i < len(std); i++ { pkgs[i] = std[i] }
	pkgs[len(std)] = xmiface.__Package()

	var it @interp.Interp = interp.New(8 * 1024 * 1024, pkgs)
	var ipaths @[]@[]char = splitColon(args[1])
	for i := 0; i < len(ipaths); i++ { it.AddBniPath(ipaths[i]) }
	var lpaths @[]@[]char = splitColon(args[2])
	for i := 0; i < len(lpaths); i++ { it.AddImplPath(lpaths[i]) }

	var loadErrs @[]@[]char = it.LoadProgram(files)
	if len(loadErrs) > 0 {
		for i := 0; i < len(loadErrs); i++ { println(loadErrs[i]) }
		os.Exit(1)
	}
	var runErrs @[]@[]char
	_, runErrs = it.RunMain()
	if len(runErrs) > 0 {
		for i := 0; i < len(runErrs); i++ { println(runErrs[i]) }
		os.Exit(1)
	}
}

// readFile reads an entire file into a byte slice (empty on error).
func readFile(path *[]readonly char) @[]uint8 {
	var f @os.File
	var err @errors.Error
	f, err = os.Open(path)
	if present(err) {
		var empty @[]uint8
		return empty
	}
	var cap int = 4096
	var data @[]uint8 = make_slice(uint8, cap)
	var total int = 0
	var readBuf @[]uint8 = make_slice(uint8, 4096)
	for {
		var n int
		n, err = f.Read(readBuf)
		if n <= 0 { break }
		for total + n > cap {
			var newCap int = cap * 2
			var newData @[]uint8 = make_slice(uint8, newCap)
			for j := 0; j < total; j++ { newData[j] = data[j] }
			data = newData
			cap = newCap
		}
		for i := 0; i < n; i++ { data[total + i] = readBuf[i] }
		total = total + n
	}
	_ = f.Close()
	return data[0:total]
}

// splitColon splits a PATH-style colon list, dropping empty entries.
func splitColon(s *[]readonly char) @[]@[]char {
	var out @[]@[]char
	if len(s) == 0 { return out }
	var start int = 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ':' {
			if i > start {
				var part @[]char = make_slice(char, i - start)
				for k := 0; k < i - start; k++ { part[k] = s[start + k] }
				out = appendCharSlice(out, part)
			}
			start = i + 1
		}
	}
	return out
}

// appendCharSlice appends a char slice to a managed slice of them.
func appendCharSlice(s @[]@[]char, v @[]char) @[]@[]char {
	var n int = len(s)
	var ns @[]@[]char = make_slice(@[]char, n + 1)
	for i := 0; i < n; i++ { ns[i] = s[i] }
	ns[n] = v
	return ns
}
EOF

# ---- dispatcher programs (run under the VM) ----
cat > "$TMP/prog_ok.bn" <<'EOF'
package "main"

import "pkg/xmiface"

func main() {
	// (a) value-receiver dispatch (iv-thunk deref).
	var w xmiface.Wrapper = xmiface.Wrapper{V: 21}
	var d *xmiface.Doubler = &w
	println(d.Double())

	// (b) multiple aggregate args.
	var adder xmiface.Adder = xmiface.Adder{Base: 100}
	var c *xmiface.Combiner = &adder
	println(c.Combine(xmiface.Pair{X: 1, Y: 2}, xmiface.Pair{X: 3, Y: 4}))

	// (c) float arg (int-slot -> FP bitcast in the shim).
	var mult xmiface.Mult = xmiface.Mult{Factor: 10}
	var s *xmiface.Scaler = &mult
	println(s.Scale(2.5))
}
EOF

cat > "$TMP/prog_overflow.bn" <<'EOF'
package "main"

import "pkg/xmiface"

func main() {
	// (d) >6 user args: the cross-mode dispatch overflow guard must fire.
	var summer xmiface.Summer = xmiface.Summer{Tag: 0}
	var m *xmiface.Many = &summer
	println(m.Sum7(1, 2, 3, 4, 5, 6, 7))
}
EOF

cat > "$TMP/prog_upcast.bn" <<'EOF'
package "main"

import "pkg/xmiface"

func main() {
	var node xmiface.Node = xmiface.Node{V: 7}
	var e *xmiface.Ext = &node
	// Child-interface dispatch (offset 0 — resolves the registered base).
	println(e.ExtVal())         // 70
	// Upcast Ext -> Base (offset>0), then dispatch the PARENT method through
	// the upcast view: the vtable word is advanced by offset*8, so the shim
	// lookup must RANGE-resolve the interior address (exact-match aborts).
	var b *xmiface.Base = e
	println(b.BaseVal())        // 7

	// Multi-level: transitive upcast C1 -> A1 (grandparent), offset>1.
	var ch xmiface.Chain = xmiface.Chain{V: 5}
	var c *xmiface.C1 = &ch
	println(c.CVal())           // 15
	var a *xmiface.A1 = c
	println(a.AVal())           // 5

	// Value-receiver PARENT method at offset>0: the iv-dispatch thunk resolves
	// through the range-lookup-selected shim slot.
	var vn xmiface.VNode = xmiface.VNode{V: 8}
	var ve *xmiface.VExt = &vn
	println(ve.VExtVal())       // 800
	var vb *xmiface.VBase = ve
	println(vb.VBaseVal())      // 8
}
EOF

# ---- build gen1, then the host (with the fixture on the search paths) ----
build_gen1
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$I_ROOT")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$L_ROOT")"
RT="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")"
HOST_BIN="$TMP/host-bin"
echo "Building cross-mode iface host..."
build_out=$("$GEN1_COMPILER" -I "$IFACES" -L "$IMPLS" --runtime "$RT" \
    --build-dir "$BUILD_DIR" -o "$HOST_BIN" "$HOST_DIR" 2>&1) || true
if [ ! -x "$HOST_BIN" ]; then
    echo "FAIL: host build"
    echo "$build_out"
    exit 1
fi

PASSES=0
FAILS=0
FAIL_NAMES=""

check_eq() {
    label="$1"; actual="$2"; expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected: $(printf '%s' "$expected" | tr '\n' '|')"
        echo "  actual:   $(printf '%s' "$actual" | tr '\n' '|')"
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# ----- passing shapes (a/b/c): value-receiver=42, multi-agg=110, float=20 ----
ok_out=$("$HOST_BIN" "$TMP/prog_ok.bn" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "cross-mode-iface-dispatch" "$ok_out" "42
110
20"

# ----- (e) offset>0 parent upcast: child dispatch=70, upcast+parent dispatch=7 --
# The parent method is dispatched through an Ext->Base upcast whose vtable word is
# advanced by offset*8; the native cross-mode path must RANGE-resolve that interior
# address to the parent sub-block of the shim vtable (a plain exact-match lookup
# aborts "no shim vtable for native interface method dispatch").
up_out=$("$HOST_BIN" "$TMP/prog_upcast.bn" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "cross-mode-iface-parent-upcast" "$up_out" "70
7
15
5
800
8"

# ----- negative shape (d): >6 user args must trip the loud overflow guard -----
# This guard lives ONLY on the native cross-mode path (dispatchCompiledIfaceMethod
# — the VM's own bytecode iface dispatch has no a0..a6 limit), so the panic firing
# also PROVES the fixture was genuinely native-injected: were it lowered to
# bytecode instead, Sum7 would just return 28 and this program would print, not
# panic.  Keep this check — it is what makes the whole test cross-mode, not a
# false pass through bytecode dispatch.
ov_out=$("$HOST_BIN" "$TMP/prog_overflow.bn" "$IFACES" "$IMPLS" 2>&1) || true
case "$ov_out" in
    *">6 user arg slots"*)
        echo "PASS: cross-mode-iface-overflow-guard"
        PASSES=$((PASSES + 1)) ;;
    *)
        echo "FAIL: cross-mode-iface-overflow-guard"
        echo "  expected a vmPanic containing '>6 user arg slots'"
        echo "  actual:   $(printf '%s' "$ov_out" | tr '\n' '|')"
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES cross-mode-iface-overflow-guard" ;;
esac

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
