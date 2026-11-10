#!/bin/sh
# e2e/injected-raw-box-assert.sh — End-to-end test that a bytecode program's
# concrete assertions hit on raw-pointer boxes of a NATIVE-INJECTED package's type
# whose own TypeInfo record reaches the VM only through its raw-origin variant's.
#
# A box made from a raw pointer carries its type's raw-origin variant record (spec
# §11.12 `iface.assert.origin`), whose canonical word names the type's own record,
# and a concrete `x.(*T)` compares that canonical record (§7.13.14).  The VM binds
# a native-injected package's records only through the package's satisfaction
# entries.  The fixture's T has no impls, and the package boxes T into `any` from
# raw pointers only, so its entries name `__raw_T` and `__readonly___raw_T` but
# never T: the VM must bind T to the record those variants name as canonical
# (vm/lower_typeinfo.bn bindViaOriginVariant), not make one of its own, or every
# assertion below misses.  The fixture makes no concrete assertion itself -- an
# assertion site would emit a `(T, any)` row and so register T's own record.
#
# A custom host injects the fixture's `__Package()` descriptor alongside
# StandardPackages() and runs the program under the VM.  Gen1 (the current tree's
# bnc, built by the BUILDER) compiles the host, which imports pkg/binate/interp,
# outside the BUILDER's cone.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_rawbox.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/xr" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture package: pkg/xr (compiled NATIVELY, injected into the VM) ----
cat > "$I_ROOT/pkg/xr.bni" <<'EOF'
package "pkg/xr"

// T has no impls; BoxRaw and BoxRO box it into `any` from raw pointers only.
type T struct {
	X int
}

// BoxRaw boxes *p, made from a raw pointer.
func BoxRaw(p *T) *any

// BoxRO boxes the readonly *p, made from a raw pointer.
func BoxRO(p *readonly T) *any
EOF
cat > "$L_ROOT/pkg/xr/xr.bn" <<'EOF'
package "pkg/xr"

func BoxRaw(p *T) *any { return p }

func BoxRO(p *readonly T) *any { return p }
EOF

# ---- the VM program: assertions on boxes made natively and in bytecode ----
cat > "$TMP/prog.bn" <<'EOF'
package "main"

import "pkg/builtins/reflect"
import "pkg/builtins/testing"
import "pkg/xr"

func main() {
	var t xr.T
	t.X = 5
	var a *any = xr.BoxRaw(&t)
	p, ok1 := a.(*xr.T)
	testing.Println(ok1)
	if ok1 { testing.Println(p.X) }
	_, ok2 := a.(xr.T)
	testing.Println(ok2)
	var r *any = xr.BoxRO(&t)
	_, ok3 := r.(*readonly xr.T)
	testing.Println(ok3)
	_, ok4 := r.(*xr.T)
	testing.Println(ok4)
	var v xr.T
	var c *any = &v
	_, ok5 := c.(*xr.T)
	testing.Println(ok5)
	testing.Println(reflect.TypeOf(a) == reflect.TypeOf(c))
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
HOST_BIN="$TMP/host-bin"
echo "Building raw-box assertion host..."
build_out=$("$GEN1_COMPILER" -I "$IFACES" -L "$IMPLS" \
    --build-dir "$BUILD_DIR" -o "$HOST_BIN" "$HOST_DIR" 2>&1) || true
if [ ! -x "$HOST_BIN" ]; then
    echo "FAIL: host build"
    echo "$build_out"
    exit 1
fi

# T's boxes hit `*xr.T`, `xr.T` and `*readonly xr.T` as their kind allows, whether
# xr made them natively or the program made them in bytecode, and reflection sees
# one dynamic type for both.
out=$("$HOST_BIN" "$TMP/prog.bn" "$IFACES" "$IMPLS" 2>&1) || true
expected="true
5
true
true
false
true
true"
if [ "$out" = "$expected" ]; then
    echo "PASS: injected-raw-box-assert"
    echo ""
    echo "=== Summary: 1 passed, 0 failed ==="
else
    echo "FAIL: injected-raw-box-assert"
    echo "  expected: $(printf '%s' "$expected" | tr '\n' '|')"
    echo "  actual:   $(printf '%s' "$out" | tr '\n' '|')"
    echo ""
    echo "=== Summary: 0 passed, 1 failed ==="
    exit 1
fi
