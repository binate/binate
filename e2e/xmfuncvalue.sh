#!/bin/sh
# e2e/xmfuncvalue.sh — End-to-end test of the REVERSE cross-mode func-value
# dispatch: NATIVELY-compiled code calling a function VALUE whose target is a
# BYTECODE-VM function.  A VM program hands a bytecode function (by value) to a
# native-injected package function, which calls it back — so the native indirect
# call goes through the VM-side trampoline (pkg/binate/vm/vm.bn):
#   - TrampolineAggregate for a MULTI-return (int, int) value (the fixed path:
#     the compiled caller uses the retbuf shim shape for any multi-return func
#     value, so the VM must select the retbuf trampoline; before the fix a
#     multi-return fell through to the one-word TrampolineScalar and the caller's
#     retbuf pointer landed in `data` — a loud closure-record-tag vmPanic, which
#     is exactly what makes this a genuine regression pin, not a false pass).
#   - TrampolineScalar for a scalar value (the control: the scalar path must stay
#     correct).
#
# This is the counterpart of xmiface.sh (which covers VM-caller -> NATIVE-callee
# interface dispatch); here the caller is NATIVE and the callee is BYTECODE, so
# it exercises ensureHandle's trampoline SELECTION and the trampoline bodies,
# which the conformance suite (whole-program, single-mode) cannot reach.
#
# Structure mirrors xmiface.sh: a custom host injects a fixture package's
# __Package() descriptor alongside StandardPackages() (so the fixture is treated
# as native-injected, not VM-lowered), then runs a bytecode program that passes
# its own functions into the fixture.  Gen1 (the current tree's bnc, built by the
# BUILDER) compiles the host, which imports pkg/binate/{interp,vm}.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_xmfv.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/xmfv" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture package: pkg/xmfv (native-injected caller of VM func values) ----
cat > "$I_ROOT/pkg/xmfv.bni" <<'EOF'
package "pkg/xmfv"

// ApplyMR calls a caller-supplied function value returning (int, int) and folds
// the two results into one word (a*1000 + b).  When the value's target is a
// BYTECODE function, this native call dispatches through TrampolineAggregate (a
// multi-return func value uses the retbuf shim shape) — the compiled->VM
// multi-return path.
func ApplyMR(f @func() (int, int)) int

// ApplyScalar calls a scalar-returning function value and returns its result —
// the TrampolineScalar control path.
func ApplyScalar(f @func() int) int
EOF

cat > "$L_ROOT/pkg/xmfv/xmfv.bn" <<'EOF'
package "pkg/xmfv"

func ApplyMR(f @func() (int, int)) int {
	var a int
	var b int
	a, b = f()
	return a * 1000 + b
}

func ApplyScalar(f @func() int) int {
	return f()
}
EOF

# ---- custom host: cmd/bni's runProgram + fixture in the VM inject-set ----
# Injecting xmfv.__Package() into interp.New's package set makes the run path
# skip lowering pkg/xmfv (Interp.isCompiled) and keep its functions NATIVE — so a
# func value the bytecode program passes into ApplyMR/ApplyScalar is called from
# native machine code, the cross-mode path under test.
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/builtins/reflect"
import "pkg/std/errors"
import "pkg/std/os"
import "pkg/xmfv"

// host <prog.bn> <I-paths colon-sep> <L-paths colon-sep>
func main() {
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
	pkgs[len(std)] = xmfv.__Package()

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
// slot at index 0 — each element copied into an owned @[]char.
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

# ---- dispatcher program (bytecode main hands its funcs to native xmfv) ----
cat > "$TMP/prog.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/xmfv"

// producerMR is a BYTECODE multi-return function.  Passed to the native
// xmfv.ApplyMR, its func value's vtable.call is TrampolineAggregate — the
// compiled->VM multi-return dispatch under test.
func producerMR() (int, int) { return 11, 22 }

// producerSc is a BYTECODE scalar function (the TrampolineScalar control).
func producerSc() int { return 7 }

func main() {
	testing.Println(xmfv.ApplyMR(producerMR))       // 11 * 1000 + 22 = 11022
	testing.Println(xmfv.ApplyScalar(producerSc))   // 7
}
EOF

# ---- build gen1, then the host (with the fixture on the search paths) ----
build_gen1
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$I_ROOT")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$L_ROOT")"
HOST_BIN="$TMP/host-bin"
echo "Building cross-mode func-value host..."
build_out=$("$GEN1_COMPILER" -I "$IFACES" -L "$IMPLS" \
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

# The multi-return line (11022) is the fixed path: with the pre-fix selection
# gate, producerMR's func value carried the one-word TrampolineScalar, so the
# native retbuf-shape call landed its retbuf pointer in `data` and the run
# aborted with a closure-record-tag vmPanic (no 11022 line).  The scalar line (7)
# is the control.
out=$("$HOST_BIN" "$TMP/prog.bn" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "cross-mode-funcvalue-dispatch" "$out" "11022
7"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
