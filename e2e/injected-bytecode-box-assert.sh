#!/bin/sh
# e2e/injected-bytecode-box-assert.sh — End-to-end test that a NATIVE-INJECTED
# package's assertions hit on boxes a bytecode program made.
#
# An interface assertion `x.(*J)` looks the box's record up together with J's
# identity marker `__ifaceid.<J>` (spec §11.12 `iface.rtti`).  When the box is of
# a bytecode type, its `(T, J)` satisfaction entry lives only in the VM's registry,
# which native rt.SatLookup consults on a miss -- keyed on the VM's binding of
# `__ifaceid.<J>`, so that binding must be the native marker the asserting code
# presents, though the fixture defines no impl of its interface G.  A concrete
# assertion compares the box's canonical record with `__typeinfo.<T>` (§7.13.14):
# a box of the fixture's U made in bytecode must carry the native record, though U
# has no impls.
#
# A custom host injects the fixture's `__Package()` descriptor alongside
# StandardPackages() and runs the program under the VM.  Gen1 (the current tree's
# bnc, built by the BUILDER) compiles the host, which imports pkg/binate/interp,
# outside the BUILDER's cone -- once with each backend, since each emits the
# descriptor's interface-identity table itself.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bcbox.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/xr" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture package: pkg/xr (compiled NATIVELY, injected into the VM) ----
cat > "$I_ROOT/pkg/xr.bni" <<'EOF'
package "pkg/xr"

// G has no impl in this package; the program implements it.
interface G {
	Get() int
}

// U has no impls.
type U struct {
	X int
}

// CallViaAny returns a's Get() through `*G`, or -1 when a does not satisfy G.
func CallViaAny(a *any) int

// CallViaAnyM returns a's Get() through `@G`, or -1.
func CallViaAnyM(a @any) int

// SwitchG returns a's Get() through a type switch's `*G` case, or -1.
func SwitchG(a *any) int

// UX returns a's X through `*U`, or -1.
func UX(a *any) int

// ROUX returns a's X through `*readonly U`, or -1.
func ROUX(a *any) int
EOF
cat > "$L_ROOT/pkg/xr/xr.bn" <<'EOF'
package "pkg/xr"

func CallViaAny(a *any) int {
	g, ok := a.(*G)
	if !ok { return -1 }
	return g.Get()
}

func CallViaAnyM(a @any) int {
	g, ok := a.(@G)
	if !ok { return -1 }
	return g.Get()
}

func SwitchG(a *any) int {
	switch g := a.(type) {
	case *G:
		return g.Get()
	}
	return -1
}

func UX(a *any) int {
	u, ok := a.(*U)
	if !ok { return -1 }
	return u.X
}

func ROUX(a *any) int {
	u, ok := a.(*readonly U)
	if !ok { return -1 }
	return u.X
}
EOF

# ---- the VM program: boxes made in bytecode, asserted natively ----
cat > "$TMP/prog.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/xr"

type L struct {
	Z int
}

func (l *L) Get() int { return l.Z }

impl *L : xr.G

func main() {
	var l L
	l.Z = 4
	var gl *xr.G = &l
	var up *any = gl
	testing.Println(xr.CallViaAny(up))
	testing.Println(xr.SwitchG(up))
	var raw *any = &l
	testing.Println(xr.CallViaAny(raw))
	var ml @L = make(L)
	ml.Z = 8
	var mgl @xr.G = ml
	var upm @any = mgl
	testing.Println(xr.CallViaAnyM(upm))
	var u xr.U
	u.X = 6
	var ua *any = &u
	testing.Println(xr.UX(ua))
	var ru *readonly xr.U = &u
	var ra *any = ru
	testing.Println(xr.ROUX(ra))
	testing.Println(xr.UX(ra))
	var mu @xr.U = make(xr.U)
	mu.X = 7
	var ma @any = mu
	testing.Println(xr.UX(ma))
}
EOF

# ---- the host: injects pkg/xr, runs <prog> under the VM ----
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/builtins/reflect"
import "pkg/std/errors"
import "pkg/std/os"
import "pkg/xr"

func main() {
	var args @[]@[]char = progArgs()
	var src @[]uint8 = readFile(args[0])
	var p @parser.Parser = parser.New(src, args[0])
	var f @ast.File = p.ParseFile()
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f
	var std @[]@reflect.Package = interp.StandardPackages()
	var pkgs @[]@reflect.Package = make_slice(@reflect.Package, len(std) + 1)
	for i := 0; i < len(std); i++ { pkgs[i] = std[i] }
	pkgs[len(std)] = xr.__Package()
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
	for i := 0; i < len(runErrs); i++ { testing.Println(runErrs[i]) }
}

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
// slot at index 0 — each element copied into an owned @[]char (os.Args()'s
// element slots are readonly, so it can't borrow straight into *[]readonly
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

# ---- build gen1, then the host (fixture package on the search paths) ----
build_gen1
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$I_ROOT")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$L_ROOT")"

# Every native assertion hits on the bytecode boxes, except `*U` on a box of a
# readonly U (iface.assert.readonly) -- with the host (and so the injected
# package's descriptor) built by each backend.
expected="4
4
4
8
6
6
-1
7"
passed=0
failed=0
check_backend() {
    _label="$1"
    shift
    _bin="$TMP/host-$_label"
    echo "Building bytecode-box assertion host ($_label)..."
    mkdir -p "$BUILD_DIR/$_label"
    _build_out=$("$GEN1_COMPILER" "$@" -I "$IFACES" -L "$IMPLS" \
        --build-dir "$BUILD_DIR/$_label" -o "$_bin" "$HOST_DIR" 2>&1) || true
    if [ ! -x "$_bin" ]; then
        echo "FAIL: injected-bytecode-box-assert ($_label): host build"
        echo "$_build_out"
        failed=$((failed + 1))
        return
    fi
    _out=$("$_bin" "$TMP/prog.bn" "$IFACES" "$IMPLS" 2>&1) || true
    if [ "$_out" = "$expected" ]; then
        echo "PASS: injected-bytecode-box-assert ($_label)"
        passed=$((passed + 1))
    else
        echo "FAIL: injected-bytecode-box-assert ($_label)"
        echo "  expected: $(printf '%s' "$expected" | tr '\n' '|')"
        echo "  actual:   $(printf '%s' "$_out" | tr '\n' '|')"
        failed=$((failed + 1))
    fi
}
check_backend llvm
check_backend native --backend native

echo ""
echo "=== Summary: $passed passed, $failed failed ==="
[ "$failed" -eq 0 ]
