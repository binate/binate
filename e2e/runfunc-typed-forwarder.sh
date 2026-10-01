#!/bin/sh
# e2e/runfunc-typed-forwarder.sh — End-to-end test of the interp's RunFuncTyped
# addressing a function through an `expose` forwarder package.
#
# A forwarder is a .bni that is only `package "X"` plus `expose "P"` statements
# and has no implementation directory of its own (spec §16.5.2): every member it
# offers IS the member of its HOME package P (`pkg.expose.identity`), and the
# forwarder emits no code of its own.  The checker resolves `X.F` through the
# forwarder's scope to P's declaration, but F is lowered exactly once, under its
# home path — the VM holds `P.F`, never `X.F`.
#
# RunFuncTyped(pkgPath, funcName, args) therefore does two lookups: the
# signature, via Checker.PackageType(pkgPath, funcName) (which sees through the
# forwarder), and the lowered function, via Vm.LookupFunc("<path>.<funcName>").
# For the second it asks Checker.PackageMemberHome(pkgPath, funcName) for the
# member's home and, when that is non-empty, qualifies the name with the HOME
# path instead of pkgPath.  Without that remap, RunFuncTyped("pkg/fwd", "Add", ...)
# resolves the signature and then reports "interp: function not lowered into the
# VM", because no `pkg/fwd.Add` exists in the VM.
#
# Fixture: a library package pkg/home (a scalar Add and a @[]readonly char Greet)
# and a forwarder pkg/fwd.bni that exposes it.  The loaded program imports only
# pkg/fwd; pkg/home is loaded as its expose dependency (`pkg.expose.dep`).  The
# host drives both functions through the forwarder path AND through the home
# path; the home calls are the control (they exercise no remap), so a regression
# shows up as the fwd.* lines failing while the home.* lines still pass.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_rftfwd.XXXXXX")"
trap 'rm -rf "$TMP"; cleanup_compilers' EXIT

I_ROOT="$TMP/iroot"
L_ROOT="$TMP/lroot"
HOST_DIR="$TMP/host"
BUILD_DIR="$TMP/build"
mkdir -p "$I_ROOT/pkg" "$L_ROOT/pkg/home" "$HOST_DIR" "$BUILD_DIR"

# ---- fixture: home package pkg/home + forwarder pkg/fwd (no impl dir) ----------
cat > "$I_ROOT/pkg/home.bni" <<'EOF'
package "pkg/home"

// Add returns a + b — a scalar-argument, scalar-result function.
func Add(a int, b int) int

// Greet returns a fixed greeting — a managed-slice result, which RunFuncTyped
// unmarshals from the retbuf rather than the return word.
func Greet() @[]readonly char
EOF

cat > "$L_ROOT/pkg/home/home.bn" <<'EOF'
package "pkg/home"

func Add(a int, b int) int {
	return a + b
}

func Greet() @[]readonly char {
	return "hello from home"
}
EOF

cat > "$I_ROOT/pkg/fwd.bni" <<'EOF'
package "pkg/fwd"

expose "pkg/home"
EOF

# ---- custom host: load the program, Init, then RunFuncTyped via fwd and via home ----
# Every call prints one line, "<label> <result>" on success or
# "<label> ERROR <msg>" on failure, and the host carries on to the next call, so
# the harness can check each path independently.
cat > "$HOST_DIR/host.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/binate/ast"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/std/os"

// progSrc is the whole-program fixture: package main importing only the
// forwarder pkg/fwd.  main is present only because LoadProgram requires a
// program to define func main; the host drives the functions directly.
var progSrc *[]readonly char = "package \"main\"\n"
		"import \"pkg/fwd\"\n"
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
		for i := 0; i < len(perrs); i++ { testing.Println(parser.FormatParseError(perrs[i])) }
		os.Exit(1)
	}
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f

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
	var initErrs @[]@[]char = it.Init()
	if len(initErrs) > 0 {
		for i := 0; i < len(initErrs); i++ { testing.Println(initErrs[i]) }
		os.Exit(1)
	}

	runAdd(it, "home.Add", "pkg/home")
	runAdd(it, "fwd.Add", "pkg/fwd")
	runGreet(it, "home.Greet", "pkg/home")
	runGreet(it, "fwd.Greet", "pkg/fwd")
}

// runAdd calls <pkgPath>.Add(2, 40) via RunFuncTyped and prints the int result.
func runAdd(it @interp.Interp, label *[]readonly char, pkgPath *[]readonly char) {
	var callArgs @[]interp.Value = make_slice(interp.Value, 2)
	callArgs[0] = interp.IntValue(2)
	callArgs[1] = interp.IntValue(40)
	var results @[]interp.Value
	var errs @[]@[]char
	results, errs = it.RunFuncTyped(pkgPath, "Add", callArgs)
	callArgs[0].Release()
	callArgs[1].Release()
	if !resultOK(label, results, errs) { return }
	testing.Println(label, results[0].AsInt())
	results[0].Release()
}

// runGreet calls <pkgPath>.Greet() via RunFuncTyped and prints the string result.
func runGreet(it @interp.Interp, label *[]readonly char, pkgPath *[]readonly char) {
	var noArgs @[]interp.Value
	var results @[]interp.Value
	var errs @[]@[]char
	results, errs = it.RunFuncTyped(pkgPath, "Greet", noArgs)
	if !resultOK(label, results, errs) { return }
	testing.Println(label, results[0].AsString())
	results[0].Release()
}

// resultOK prints "<label> ERROR <msg>" for a failed call (an error, or not
// exactly one result, releasing any results) and reports whether the call
// produced exactly one result with no error.
func resultOK(label *[]readonly char, results @[]interp.Value, errs @[]@[]char) bool {
	if len(errs) > 0 {
		for i := 0; i < len(errs); i++ { testing.Println(label, "ERROR", errs[i]) }
		for i := 0; i < len(results); i++ { results[i].Release() }
		return false
	}
	if len(results) != 1 {
		testing.Println(label, "ERROR expected exactly one result")
		for i := 0; i < len(results); i++ { results[i].Release() }
		return false
	}
	return true
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
// element slots are readonly, so it can't borrow straight into *[]readonly char).
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

# ---- build gen1, then the host (fixture packages on the search paths) ----
build_gen1
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$I_ROOT")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$L_ROOT")"
HOST_BIN="$TMP/host-bin"
echo "Building RunFuncTyped forwarder host..."
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

# line_for <label> prints the host's output line(s) for one call.
line_for() {
    printf '%s\n' "$out" | grep "^$1 " || true
}

out=$("$HOST_BIN" "$IFACES" "$IMPLS" 2>&1) || true
check_eq "runfunc-typed-home-add" "$(line_for home.Add)" "home.Add 42"
check_eq "runfunc-typed-fwd-add" "$(line_for fwd.Add)" "fwd.Add 42"
check_eq "runfunc-typed-home-greet" "$(line_for home.Greet)" "home.Greet hello from home"
check_eq "runfunc-typed-fwd-greet" "$(line_for fwd.Greet)" "fwd.Greet hello from home"
# The whole output must be exactly those four lines (no load errors, no faults).
check_eq "runfunc-typed-forwarder-output" "$out" "home.Add 42
fwd.Add 42
home.Greet hello from home
fwd.Greet hello from home"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
