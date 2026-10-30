#!/bin/sh
# e2e/bni-only-var-undefined.sh — A package with only a `.bni` (spec §16.1) declares
# its vars extern: a `.bni` `var` only declares the variable, and its storage is the
# implementation's (decl.var.extern, §16.5) -- a compiled library's, when the package
# ships as interface + library (§16.5.1).  So with no implementation anywhere, a
# program reading such a var must fail loudly instead of reading storage of its own:
#   1. bnc's link reports the var's undefined symbol and exits non-zero;
#   2. bni does not load the program -- the VM's counterpart of that link error --
#      reporting "nothing in the program defines the package variable pkg/solo.V
#      (used by main.main, line 7)", and exits non-zero;
#   3. a reference only in code that is never lowered or linked -- a generic
#      function nothing instantiates -- is no error on either, nor is a constant
#      folded from `len` of an array var: bnc builds and runs it, and so does bni;
#   4. the REPL reports each prompt entry whose code needs the var, keeps none of
#      it -- a declaration is not kept, a redefinition leaves the old definition, an
#      import of a package that needs it (or imports one that does) is not made, a
#      parked declaration resolving later stays parked -- and the session goes on;
#   5. bni --test of a package that needs it reports it and exits non-zero;
#   6. an embedder's interp.LoadCallable of a driver package that needs it returns
#      the load error.
#
# bnc is a gen1 (BUILDER -> gen1) and bni is built by it, as in e2e/bni-nil-check.sh,
# and so is step 6's host.
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnionlyvar.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Build gen1 bnc (BUILDER -> gen1) and bni with it -----
echo "Building gen1 bnc and bni..."
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"

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

# ----- Fixture: pkg/solo has only a .bni declaring `var V int`; main reads it. -----
SRC="$TMP/src"
mkdir -p "$SRC/pkg"
cat > "$SRC/pkg/solo.bni" <<'EOF'
package "pkg/solo"

// V and A are declared, but nothing defines them.
var V int
var A [4]int
EOF
cat > "$SRC/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/solo"

func main() {
	testing.Println(solo.V)
}
EOF
# pkg/user's .bn reads solo.V; pkg/userdep imports pkg/user.
mkdir -p "$SRC/pkg/user" "$SRC/pkg/userdep"
cat > "$SRC/pkg/user.bni" <<'EOF'
package "pkg/user"

func U() int
func W() int
EOF
cat > "$SRC/pkg/user/user.bn" <<'EOF'
package "pkg/user"

import "pkg/solo"

func U() int { return solo.V }
func W() int { return 5 }
EOF
cat > "$SRC/pkg/user/user_test.bn" <<'EOF'
package "pkg/user"

import "pkg/builtins/testing"

func TestW() testing.TestResult {
	if W() != 5 { return "W should be 5" }
	return ""
}
EOF
cat > "$SRC/pkg/userdep.bni" <<'EOF'
package "pkg/userdep"

func Y() int
EOF
cat > "$SRC/pkg/userdep/userdep.bn" <<'EOF'
package "pkg/userdep"

import "pkg/user"

func Y() int { return user.W() }
EOF
IFACES="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --prepend "$SRC")"
IMPLS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --prepend "$SRC")"

FAILS=0
UNDEF_V='nothing in the program defines the package variable pkg/solo.V'

# ----- 1. bnc: the link fails, naming the var's symbol (bn_G…solo…V). -----
mkdir -p "$TMP/b1"
bnc_out=$(cd "$SRC" && "$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b1" \
    -o "$TMP/prog" main.bn 2>&1)
bnc_rc=$?
if [ "$bnc_rc" -eq 0 ]; then
    echo "FAIL: bnc built a program reading a var nothing defines (it printed: $("$TMP/prog" 2>&1))"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bnc_out" | grep -q 'bn_G[0-9_]*pkg4_solo1_1_V'; then
    echo "FAIL: bnc failed, but not on the var's undefined symbol:"
    printf '%s\n' "$bnc_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bnc's link reports the undefined var"
fi

# ----- 2. bni: the program does not load, naming the var and its use. -----
bni_out=$(cd "$SRC" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" main.bn 2>&1)
bni_rc=$?
if [ "$bni_rc" -eq 0 ]; then
    echo "FAIL: bni ran a program reading a var nothing defines (it printed: $bni_out)"
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$bni_out" | grep -qxF "$UNDEF_V (used by main.main, line 7)"; then
    echo "FAIL: bni failed, but not naming the var:"
    printf '%s\n' "$bni_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bni reports the undefined var"
fi

# ----- 3. A reference in code never lowered, and a folded constant, need nothing. -----
mkdir -p "$SRC/unused"
cat > "$SRC/unused/main.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/solo"

func G[T any]() int { return solo.V }

const N int = len(solo.A)

func main() {
	testing.Println(N)
}
EOF
mkdir -p "$TMP/b3"
unused_bnc=$(cd "$SRC/unused" && "$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b3" \
    -o "$TMP/unused" main.bn 2>&1 && "$TMP/unused" 2>&1)
unused_bnc_rc=$?
unused_bni=$(cd "$SRC/unused" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" main.bn 2>&1)
unused_bni_rc=$?
if [ "$unused_bnc_rc" -ne 0 ] || [ "$unused_bnc" != "4" ]; then
    echo "FAIL: bnc should build and run it (rc=$unused_bnc_rc):"
    printf '%s\n' "$unused_bnc" | tail -5
    FAILS=$((FAILS + 1))
elif [ "$unused_bni_rc" -ne 0 ] || [ "$unused_bni" != "4" ]; then
    echo "FAIL: bni should run it (rc=$unused_bni_rc):"
    printf '%s\n' "$unused_bni" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: an uninstantiated generic and a folded constant need no definition"
fi

# ----- 4. bni --repl: each entry needing the var fails alone; the session goes on. -----
cat > "$SRC/repl.bn" <<'EOF'
package "main"

func main() {
}
EOF
repl_out=$(cd "$SRC" && printf '%s\n' \
    'import "pkg/builtins/testing"' \
    'import "pkg/solo"' \
    'x := solo.V' \
    'func f() int { return solo.V }' \
    'f()' \
    'func G[T any]() int { return solo.V }' \
    'x2 := G[int]()' \
    'y := G[int]()' \
    'const N int = len(solo.A)' \
    'testing.Println(N)' \
    'var v int = solo.V' \
    'testing.Println(v)' \
    'func h() int { return 1 }' \
    'func h() int { return solo.V }' \
    'testing.Println(h())' \
    'func K[T any]() int { return 2 }' \
    'testing.Println(K[int]())' \
    'func K[T any]() int { return solo.V }' \
    'testing.Println(K[int]())' \
    'func Q[T any]() int { return 3 }' \
    '_ = Q[int]() + solo.V' \
    'testing.Println(Q[int]())' \
    'func pf() int { return pg() + solo.V }' \
    'func pg() int { return 1 }' \
    'testing.Println(pg())' \
    'import "pkg/userdep"' \
    'testing.Println(userdep.Y())' \
    'testing.Println(7)' |
    "$BNI_BIN" -I "$IFACES" -L "$IMPLS" --repl repl.bn 2>&1)
repl_rc=$?
undef_count=$(printf '%s\n' "$repl_out" |
    grep -c 'nothing in the program defines the package variable pkg/solo\.')
if [ "$repl_rc" -ne 0 ] || printf '%s\n' "$repl_out" | grep -q 'panic'; then
    echo "FAIL: the REPL session did not survive the entries (rc=$repl_rc):"
    printf '%s\n' "$repl_out" | tail -8
    FAILS=$((FAILS + 1))
elif [ "$undef_count" -ne 10 ]; then
    echo "FAIL: expected 10 load errors (x, f, G[int] twice, v, h, K, Q's use, pf, pkg/user), got $undef_count:"
    printf '%s\n' "$repl_out" | tail -12
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$repl_out" | grep -q 'undefined: f$' ||
        ! printf '%s\n' "$repl_out" | grep -q 'undefined: v$' ||
        ! printf '%s\n' "$repl_out" | grep -q 'function pf still parked (it does not load)$' ||
        ! printf '%s\n' "$repl_out" | grep -q 'not imported.*: pkg/userdep$' ||
        ! printf '%s\n' "$repl_out" | grep -q 'undefined: userdep$'; then
    echo "FAIL: f, v and the import of pkg/userdep should not be kept, nor pf resolve:"
    printf '%s\n' "$repl_out" | tail -12
    FAILS=$((FAILS + 1))
elif [ "$(printf '%s\n' "$repl_out" | grep -E '^(> )+[0-9]+$' | sed 's/^[> ]*//' | tr '\n' ' ')" != \
        "4 1 2 2 3 1 7 " ]; then
    echo "FAIL: expected N (4), the old h (1), K[int] around its failed redefinition (2, 2),"
    echo "      Q[int], generated again after a failed entry (3), pg, kept as pf fails (1), and 7:"
    printf '%s\n' "$repl_out" | tail -12
    FAILS=$((FAILS + 1))
else
    echo "PASS: the REPL reports each entry needing the var, keeps none of it, and goes on"
fi

# ----- 5. bni --test: a package that does not load is reported. -----
test_out=$(cd "$SRC" && "$BNI_BIN" -I "$IFACES" -L "$IMPLS" --test pkg/user 2>&1)
test_rc=$?
if [ "$test_rc" -eq 0 ]; then
    echo "FAIL: bni --test ran a package that needs a var nothing defines:"
    printf '%s\n' "$test_out" | tail -5
    FAILS=$((FAILS + 1))
elif ! printf '%s\n' "$test_out" | grep -qxF "$UNDEF_V (used by pkg/user.U, line 5)"; then
    echo "FAIL: bni --test failed, but not naming the var and its use:"
    printf '%s\n' "$test_out" | tail -5
    FAILS=$((FAILS + 1))
else
    echo "PASS: bni --test reports the package's load error"
fi

# ----- 6. interp.LoadCallable: a driver package that does not load is an error. -----
mkdir -p "$TMP/host" "$TMP/b6"
cat > "$TMP/host/host.bn" <<'EOF'
package "main"

import "pkg/binate/ast"
import "pkg/binate/buf"
import "pkg/binate/interp"
import "pkg/binate/parser"
import "pkg/builtins/testing"
import "pkg/std/os"

// driverSrc is a driver package whose D reads solo.V.
var driverSrc *[]readonly char = "package \"driver\"\n"
		"import \"pkg/solo\"\n"
		"func D() int { return solo.V }\n"
		"func E() int { return 6 }\n"

// main loads driverSrc with LoadCallable and prints the errors it returns, or
// "loaded".  Its arguments are the interface and implementation search paths, as
// colon-separated lists.
func main() {
	var args @[]readonly @[]readonly char = os.Args()
	if len(args) != 3 {
		testing.Println("usage: host <I-paths> <L-paths>")
		os.Exit(2)
	}
	var it @interp.Interp = interp.New(8 * 1024 * 1024, interp.StandardPackages())
	addPaths(it, args[1], false)
	addPaths(it, args[2], true)
	var src @[]uint8 = make_slice(uint8, len(driverSrc))
	for i := 0; i < len(driverSrc); i++ { src[i] = cast(uint8, driverSrc[i]) }
	var p @parser.Parser = parser.New(src, "driver.bn")
	var f @ast.File = p.ParseFile()
	var perrs @[]parser.ParseError = p.Errors()
	if len(perrs) > 0 {
		for i := 0; i < len(perrs); i++ { testing.Println(parser.FormatParseError(perrs[i])) }
		os.Exit(1)
	}
	var files @[]@ast.File = make_slice(@ast.File, 1)
	files[0] = f
	var errs @[]@[]char = it.LoadCallable(files, buf.CopyStr("driver"))
	if len(errs) == 0 { testing.Println("loaded") }
	for i := 0; i < len(errs); i++ { testing.Println(errs[i]) }
}

// addPaths adds each directory of the colon-separated list as an implementation
// search path (isImpl) or an interface one.
func addPaths(it @interp.Interp, list *[]readonly char, isImpl bool) {
	var start int = 0
	for i := 0; i <= len(list); i++ {
		if i < len(list) && list[i] != ':' { continue }
		if i > start && isImpl {
			it.AddImplPath(buf.CopyStr(list[start:i]))
		} else if i > start {
			it.AddBniPath(buf.CopyStr(list[start:i]))
		}
		start = i + 1
	}
}
EOF
host_build=$("$GEN1_BNC" -I "$IFACES" -L "$IMPLS" --build-dir "$TMP/b6" \
    -o "$TMP/host-bin" "$TMP/host" 2>&1)
if [ ! -x "$TMP/host-bin" ]; then
    echo "FAIL: the LoadCallable host did not build:"
    printf '%s\n' "$host_build" | tail -5
    FAILS=$((FAILS + 1))
else
    host_out=$("$TMP/host-bin" "$IFACES" "$IMPLS" 2>&1)
    host_rc=$?
    if [ "$host_rc" -ne 0 ] ||
            ! printf '%s\n' "$host_out" | grep -qxF "$UNDEF_V (used by driver.D, line 3)"; then
        echo "FAIL: LoadCallable should return the load error (rc=$host_rc):"
        printf '%s\n' "$host_out" | tail -5
        FAILS=$((FAILS + 1))
    else
        echo "PASS: LoadCallable returns the driver package's load error"
    fi
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
