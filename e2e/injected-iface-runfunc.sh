#!/bin/sh
# e2e/injected-iface-runfunc.sh — End-to-end test of the interp's RunFuncTyped
# path returning after a NATIVE-INJECTED interface-method dispatch.
#
# The interp native-injects the standard library: pkg/std/errors is in the default
# inject-set (StandardPackages / stdPkgs), so Interp.isCompiled — via the
# CompiledSet New is given — skips lowering it, and injectPackageSet ->
# RegisterPackageVtables registers its @__ivt / @__ivtshim as native.  A value the
# program gets from errors.New(...) is therefore a @errors.Error whose vtable WORD
# is a native @__ivt.  When BYTECODE-lowered code calls .Error() on it, the VM's
# execCallIfaceMethod sees ifaceVtIsNative and dispatches through
# dispatchCompiledIfaceMethod -> lookupShimVtable (pkg/binate/vm/vtable_inject.bn)
# — the native-injected branch.
#
# That branch has no dedicated unit test (loadSelfContained is single-package, so
# every impl it holds is VM-lowered — the OTHER dispatch branch; and a native
# @__ivtshim can't be hand-forged at the VM unit level).  The sibling xmiface.sh
# covers the branch via a CUSTOM fixture package driven by RunMain; this test
# instead covers the REAL stdlib (pkg/std/errors, native-injected by the default
# StandardPackages) reached through the interp's typed-marshaling entry point,
# RunFuncTyped.
#
# Attribution note: the assertions check the rendered message, which is identical
# whether errors is native-injected or bytecode-lowered, so the test does not
# itself OBSERVE the native branch (unlike xmiface.sh's >6-arg overflow guard,
# which fires only on dispatchCompiledIfaceMethod).  That errors IS native-injected
# is a structural invariant, not an observation: one table (stdPkgs) feeds both the
# lowering-skip and the injection, and scripts/hygiene/stdlib-injected.sh enforces
# every pkg/std .bni appears there — so a "lower errors instead" regression cannot
# arise without failing hygiene.  A broken lookupShimVtable, by contrast, DOES fail
# this test loudly: dispatchCompiledIfaceMethod vmPanics on a 0 shim, aborting the
# run so the captured output no longer equals the expected strings.
#
# RunFuncTyped addresses a function by its FULL import path (its doc example is
# pkg/std/strconv), so the driven functions live in a small LIBRARY package
# (pkg/errtest) the loaded program imports — a normal, VM-LOWERED package (not in
# the inject-set), so its bytecode body is what dispatches into native errors.
# The program's main package exists only because LoadProgram requires func main;
# RunFuncTyped calls pkg/errtest.{Describe,Wrapped} directly.
#
# The host is compiled by gen1 (the current tree's bnc, built by the BUILDER): it
# imports pkg/binate/{interp,parser,ast}, which are outside the BUILDER's cone.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_injiface.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/errtest" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture library package: pkg/errtest (VM-LOWERED, imports stdlib errors) --
# Its bytecode body constructs a native-injected @errors.Error and dispatches
# .Error() on it — the cross-mode native-injected dispatch under test.
cat > "$I_ROOT/pkg/errtest.bni" <<'EOF'
package "pkg/errtest"

// Describe renders a leaf errors.New(...) — the plain native-injected dispatch.
func Describe() @[]readonly char

// Wrapped renders errors.Wrap(errors.New(...), "ctx") == "ctx: boom" — a second
// dispatch that distinguishes correct method resolution from "any method": a
// mis-resolved shim slot would not carry the wrapped context.
func Wrapped() @[]readonly char
EOF

cat > "$L_ROOT/pkg/errtest/errtest.bn" <<'EOF'
package "pkg/errtest"

import "pkg/std/errors"

func Describe() @[]readonly char {
	var e @errors.Error = errors.New("boom")
	return e.Error()
}

func Wrapped() @[]readonly char {
	var e @errors.Error = errors.Wrap(errors.New("boom"), "ctx")
	return e.Error()
}
EOF

# ---- custom host: load a whole program, then RunFuncTyped the fixture funcs ----
# The inject-set is the default StandardPackages() (the pkg/std packages), so
# pkg/std/errors runs as its native compiled instance.  The embedded program
# imports pkg/errtest (which imports errors); the host then RunFuncTyped's the
# fixture functions and prints each @[]readonly char result, so the harness can
# assert the string the native-injected dispatch produced.
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/std/os"

// progSrc is the whole-program fixture: package main importing the VM-lowered
// pkg/errtest.  main is present only because LoadProgram requires a program to
// define func main; the host drives pkg/errtest.{Describe,Wrapped} directly.
var progSrc *[]readonly char = "package \"main\"\n"
		"import \"pkg/errtest\"\n"
		"func main() {}\n"

// host <I-paths colon-sep> <L-paths colon-sep>
func main() {
	var args @[]@[]char = progArgs()
	if len(args) < 2 {
		testing.Println("usage: host <I-paths> <L-paths>")
		os.Exit(1)
	}
	var p @parser.Parser = parser.New(strToBytes(progSrc), "prog.bn")
	var f @ast.File = p.ParseFile()
	var perrs @[]parser.ParseError = p.Errors()
	if len(perrs) > 0 {
		for i := 0; i < len(perrs); i++ { testing.Println(perrs[i].Msg) }
		os.Exit(1)
	}
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f

	// Pass the default inject-set, StandardPackages() (the pkg/std packages), which
	// native-injects pkg/std/errors: errors.New / .Error run as compiled code, so
	// the @errors.Error pkg/errtest dispatches on carries a native @__ivt (the path
	// under test).
	var it @interp.Interp = interp.New(8 * 1024 * 1024, interp.StandardPackages())
	var ipaths @[]@[]char = splitColon(args[0])
	for i := 0; i < len(ipaths); i++ { it.AddBniPath(ipaths[i]) }
	var lpaths @[]@[]char = splitColon(args[1])
	for i := 0; i < len(lpaths); i++ { it.AddImplPath(lpaths[i]) }

	var loadErrs @[]@[]char = it.LoadProgram(files)
	if len(loadErrs) > 0 {
		for i := 0; i < len(loadErrs); i++ { testing.Println(loadErrs[i]) }
		os.Exit(1)
	}

	printResult(it, "Describe")
	printResult(it, "Wrapped")
}

// printResult runs pkg/errtest.<fn> (a zero-arg function) via RunFuncTyped and
// prints its single @[]readonly char result — the string produced by dispatching
// .Error() on a native-injected @errors.Error (execCallIfaceMethod ->
// dispatchCompiledIfaceMethod -> lookupShimVtable).
func printResult(it @interp.Interp, fn *[]readonly char) {
	var noArgs @[]interp.Value
	var results @[]interp.Value
	var errs @[]@[]char
	results, errs = it.RunFuncTyped("pkg/errtest", fn, noArgs)
	if len(errs) > 0 {
		for i := 0; i < len(errs); i++ { testing.Println(errs[i]) }
		os.Exit(1)
	}
	if len(results) != 1 {
		testing.Println("host: expected exactly one result")
		os.Exit(1)
	}
	testing.Println(results[0].AsString())
	results[0].Release()
}

// strToBytes copies readonly source text into an owned byte buffer for the parser.
func strToBytes(s *[]readonly char) @[]uint8 {
	var b @[]uint8 = make_slice(uint8, len(s))
	for i := 0; i < len(s); i++ { b[i] = cast(uint8, s[i]) }
	return b
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
// element slots are readonly, so it can't borrow straight into *[]readonly char),
// matching cmd/bni's / cmd/bnas's own os.Args bridge.
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
echo "Building injected-iface RunFuncTyped host..."
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

# Describe() -> errors.New("boom").Error()               == "boom"
# Wrapped()  -> errors.Wrap(errors.New("boom"), "ctx").Error() == "ctx: boom"
out=$("$HOST_BIN" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "runfunc-injected-iface-dispatch" "$out" "boom
ctx: boom"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
