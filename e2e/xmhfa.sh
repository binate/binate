#!/bin/sh
# e2e/xmhfa.sh — End-to-end test of CROSS-MODE dispatch of HOMOGENEOUS
# FLOATING-POINT AGGREGATES (HFAs): a program running under the bytecode VM
# dispatching interface methods — whose implementations are COMPILED machine
# code (native-injected) — that take and return HFAs.
#
# This is the VM<->compiled-code boundary for HFA passing, which the conformance
# suite structurally cannot reach: in the VM modes a synthetic package is
# lowered to bytecode (no compiled dispatch), and in the native modes the caller
# is compiled too (no VM marshalling).  This test is the only place the VM's own
# cross-mode HFA marshalling runs — the VM packs an HFA arg into ONE by-address
# `_call_shim_*` slot and reads an HFA result back through the retbuf (sized by
# types.AggregateReturnSize, which HFAs deliberately keep on the retbuf path) —
# together with the compiled shim's HFA member marshalling (v0..v3).  Mirrors
# e2e/xmiface.sh's native-injection mechanism; case (c) there covers a float
# SCALAR arg, this covers 16/24/32-byte HFA args and a 24-byte HFA return.
#
# The fixture's impls run as compiled machine code (the host links them and
# injects their descriptor); the dispatching main runs as bytecode.  Gen1 (the
# current tree's bnc) compiles the host, which imports pkg/binate/{interp,vm}.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_xmhfa.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/xmhfa" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture package: pkg/xmhfa (HFA interface impls, compiled machine code) --
cat > "$I_ROOT/pkg/xmhfa.bni" <<'EOF'
package "pkg/xmhfa"

// D2/D3/D4 are 2/3/4-member float64 HFAs (16/24/32 bytes).  The interface
// methods take them as ARGS (Sum*) and return one as a RESULT (Mk3), all
// crossing the VM<->compiled boundary via the cross-mode dispatch shim.
type D2 struct { x float64; y float64 }
type D3 struct { a float64; b float64; c float64 }
type D4 struct { p float64; q float64; r float64; s float64 }

interface HfaOps {
	Sum2(v D2) float64
	Sum3(v D3) float64
	Sum4(v D4) float64
	Mk3(z float64) D3
}
type Impl struct { Base float64 }
func (m *Impl) Sum2(v D2) float64
func (m *Impl) Sum3(v D3) float64
func (m *Impl) Sum4(v D4) float64
func (m *Impl) Mk3(z float64) D3
impl *Impl : HfaOps

// A >6-user-arg method used as a CROSS-MODE PROOF: the a0..a6 overflow guard
// fires only on the compiled cross-mode dispatch path (the VM's own bytecode
// iface dispatch has no such limit), so its loud panic proves the fixture is
// genuinely native-injected — were it lowered to bytecode, Sum7 would just
// return, making the HFA checks above a false pass.
interface Big {
	Sum7(a int, b int, c int, d int, e int, f int, g int) int
}
func (m *Impl) Sum7(a int, b int, c int, d int, e int, f int, g int) int
impl *Impl : Big
EOF

cat > "$L_ROOT/pkg/xmhfa/xmhfa.bn" <<'EOF'
package "pkg/xmhfa"

func (m *Impl) Sum2(v D2) float64 { return v.x + v.y + m.Base }
func (m *Impl) Sum3(v D3) float64 { return v.a + v.b + v.c + m.Base }
func (m *Impl) Sum4(v D4) float64 { return v.p + v.q + v.r + v.s + m.Base }
func (m *Impl) Mk3(z float64) D3 {
	var r D3
	r.a = z
	r.b = z * 2.0
	r.c = m.Base
	return r
}

func (m *Impl) Sum7(a int, b int, c int, d int, e int, f int, g int) int {
	return cast(int, m.Base) + a + b + c + d + e + f + g
}
EOF

# ---- custom host: cmd/bni's runProgram + fixture in the VM inject-set ----
# Adding xmhfa.__Package() to interp.New's package set makes the run path skip
# lowering pkg/xmhfa (Interp.isCompiled) and dispatch its methods as compiled
# machine code — the cross-mode path under test.  (Mirrors e2e/xmiface.sh.)
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/builtins/reflect"
import "pkg/std/errors"
import "pkg/std/os"
import "pkg/xmhfa"

// host <prog.bn> <I-paths colon-sep> <L-paths colon-sep>
func main() {
	// progArgs() re-derives the no-program-name argv shape bootstrap.Args() used to
	// return (retired when argv moved to pkg/builtins/startup behind os.Args), so
	// args[0] is the first real arg and the indices below are unchanged.
	var args @[]@[]char = progArgs()
	if len(args) < 3 {
		testing.Println("usage: host <prog.bn> <I-paths> <L-paths>")
		os.Exit(1)
	}
	var src @[]uint8 = readFile(args[0])
	if len(src) == 0 {
		testing.Print("host: cannot read ")
		testing.Println(args[0])
		os.Exit(1)
	}
	var p @parser.Parser = parser.New(src, args[0])
	var f @ast.File = p.ParseFile()
	var perrs @[]parser.ParseError = p.Errors()
	if len(perrs) > 0 {
		for i := 0; i < len(perrs); i++ { testing.Println(perrs[i].Msg) }
		os.Exit(1)
	}
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f

	// Inject-set = the standard library plus the fixture package, so the fixture
	// is treated as native-injected (not lowered) by the run path.
	var std @[]@reflect.Package = interp.StandardPackages()
	var pkgs @[]@reflect.Package = make_slice(@reflect.Package, len(std) + 1)
	for i := 0; i < len(std); i++ { pkgs[i] = std[i] }
	pkgs[len(std)] = xmhfa.__Package()

	var it @interp.Interp = interp.New(8 * 1024 * 1024, pkgs)
	var ipaths @[]@[]char = splitColon(args[1])
	for i := 0; i < len(ipaths); i++ { it.AddBniPath(ipaths[i]) }
	var lpaths @[]@[]char = splitColon(args[2])
	for i := 0; i < len(lpaths); i++ { it.AddImplPath(lpaths[i]) }

	var loadErrs @[]@[]char = it.LoadProgram(files)
	if len(loadErrs) > 0 {
		for i := 0; i < len(loadErrs); i++ { testing.Println(loadErrs[i]) }
		os.Exit(1)
	}
	var runErrs @[]@[]char
	_, runErrs = it.RunMain()
	if len(runErrs) > 0 {
		for i := 0; i < len(runErrs); i++ { testing.Println(runErrs[i]) }
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

// progArgs returns the host's own arguments — os.Args() minus the program-name
// slot at index 0 — each element copied into an owned @[]char.  This is the
// no-program-name shape the retired bootstrap.Args() used to return (its
// element slots readonly, os.Args() can't borrow straight into *[]readonly
// char), matching cmd/bni's / cmd/bnas's own os.Args bridge.
func progArgs() @[]@[]char {
	var full @[]readonly @[]readonly char = os.Args()
	var n int = len(full)
	if n <= 1 { return make_slice(@[]char, 0) }
	var out @[]@[]char = make_slice(@[]char, n - 1)
	for i := 1; i < n; i++ {
		var m int = len(full[i])
		var s @[]char = make_slice(char, m)
		for j := 0; j < m; j++ { s[j] = full[i][j] }
		out[i - 1] = s
	}
	return out
}
EOF

# ---- dispatcher program (run under the VM) ----
cat > "$TMP/prog.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/xmhfa"

func main() {
	var im xmhfa.Impl = xmhfa.Impl{Base: 100.0}
	var iv *xmhfa.HfaOps = &im

	// HFA ARGS crossing bytecode -> compiled dispatch (by-address slot -> v0..v3).
	var a xmhfa.D2
	a.x = 4.0
	a.y = 6.0
	testing.Println(cast(int, iv.Sum2(a)))                 // 110  (16B)

	var b xmhfa.D3
	b.a = 1.0
	b.b = 2.0
	b.c = 3.0
	testing.Println(cast(int, iv.Sum3(b)))                 // 106  (24B)

	var d xmhfa.D4
	d.p = 1000.0
	d.q = 200.0
	d.r = 30.0
	d.s = 4.0
	testing.Println(cast(int, iv.Sum4(d)))                 // 1334 (32B)

	// HFA RESULT crossing compiled -> bytecode (v0..v2 -> retbuf -> VM).
	var t xmhfa.D3 = iv.Mk3(3.0)
	testing.Println(cast(int, t.a + t.b + t.c))            // 109  (3 + 6 + 100)
}
EOF

# Cross-mode PROOF: dispatching a >6-user-arg method must trip the compiled
# cross-mode overflow guard (a loud panic), proving the fixture is genuinely
# native-injected rather than lowered to bytecode (see the fixture .bni).
cat > "$TMP/prog_overflow.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/xmhfa"

func main() {
	var im xmhfa.Impl = xmhfa.Impl{Base: 0.0}
	var iv *xmhfa.Big = &im
	testing.Println(iv.Sum7(1, 2, 3, 4, 5, 6, 7))
}
EOF

# ---- build gen1, then the host (with the fixture on the search paths) ----
build_gen1
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$I_ROOT")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$L_ROOT")"
RT="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")"
HOST_BIN="$TMP/host-bin"
echo "Building cross-mode HFA host..."
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

out=$("$HOST_BIN" "$TMP/prog.bn" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "cross-mode-hfa-dispatch" "$out" "110
106
1334
109"

# Cross-mode proof: the >6-arg overflow guard fires only on the compiled
# cross-mode path, so its panic proves the HFA dispatch above was genuinely
# cross-mode (not a bytecode-lowered false pass).
ov_out=$("$HOST_BIN" "$TMP/prog_overflow.bn" "$IFACES" "$IMPLS" 2>&1) || true
case "$ov_out" in
    *">6 user arg slots"*)
        echo "PASS: cross-mode-hfa-proof (overflow guard)"
        PASSES=$((PASSES + 1)) ;;
    *)
        echo "FAIL: cross-mode-hfa-proof (overflow guard)"
        echo "  expected a vmPanic containing '>6 user arg slots'"
        echo "  actual:   $(printf '%s' "$ov_out" | tr '\n' '|')"
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES cross-mode-hfa-proof" ;;
esac

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
