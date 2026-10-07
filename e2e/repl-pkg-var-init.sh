#!/bin/sh
# e2e/repl-pkg-var-init.sh — Packages are initialized at the REPL as in a
# program: package initialization (prog.init.vars) runs, dependencies first,
# before a package is used — the main file's own, and an imported package's,
# whether imported by the main file or at the prompt.  A variable read directly,
# through the package's own function, or by a generic function's body
# monomorphized at the prompt (of a package that imports it, which the session
# does not), holds its initializer's value.  A fault in an initializer at startup
# is a setup error.  At the prompt it is reported, the package — and any package
# that imports it — is not imported, the other packages of the import are, and
# the session goes on.
#
# bni is built from source (scripts/build-bni.sh).
#
# Exit 0 on full pass; non-zero with diagnostics on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
PATHS="$BINATE_DIR/scripts/binate-paths.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_repl_var_init.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNI_BIN="$TMP/bni"
if ! "$BINATE_DIR/scripts/build-bni.sh" -o "$BNI_BIN" >"$TMP/build.log" 2>&1; then
    echo "FAIL: bni build failed:"
    cat "$TMP/build.log"
    exit 1
fi

mkdir -p "$TMP/pkg/hv" "$TMP/pkg/gv"
cat > "$TMP/pkg/hv.bni" <<'EOF2'
package "pkg/hv"

var V int

func GetV() int

func GetW() int
EOF2
cat > "$TMP/pkg/hv/hv.bn" <<'EOF2'
package "pkg/hv"

var V int = 2

var w int = 3

func GetV() int { return V }

func GetW() int { return w }
EOF2
cat > "$TMP/pkg/gv.bni" <<'EOF2'
package "pkg/gv"

import "pkg/hv"

func Read[T any]() int { return hv.V }
EOF2
cat > "$TMP/pkg/gv/gv.bn" <<'EOF2'
package "pkg/gv"
EOF2
mkdir -p "$TMP/pkg/bad"
cat > "$TMP/pkg/bad.bni" <<'EOF2'
package "pkg/bad"

var N int
EOF2
cat > "$TMP/pkg/bad/bad.bn" <<'EOF2'
package "pkg/bad"

type T struct {
    n int
}

func nilp() *T { return nil }

var N int = nilp().n
EOF2
mkdir -p "$TMP/pkg/usesbad"
cat > "$TMP/pkg/usesbad.bni" <<'EOF2'
package "pkg/usesbad"

var M int
EOF2
cat > "$TMP/pkg/usesbad/usesbad.bn" <<'EOF2'
package "pkg/usesbad"

import "pkg/bad"

var M int = bad.N + 1
EOF2
cat > "$TMP/imports.bn" <<'EOF2'
package "main"

import "pkg/builtins/testing"
import "pkg/gv"
import "pkg/hv"

var Count int = 50

func main() { testing.Println(hv.V) }
EOF2
cat > "$TMP/badinit.bn" <<'EOF2'
package "main"

import "pkg/builtins/testing"
import "pkg/bad"

func main() { testing.Println(bad.N) }
EOF2
cat > "$TMP/plain.bn" <<'EOF2'
package "main"

import "pkg/builtins/testing"

func main() { testing.Println(0) }
EOF2

BANNER="Binate REPL (Tier 1 PoC). Ctrl-D to exit."
FAILS=0

run_repl() { # label fixture input expected
    actual=$(printf '%s' "$3" | "$BNI_BIN" --repl \
        -I "$("$PATHS" --iface --base "$BINATE_DIR")" -L "$("$PATHS" --impl --base "$BINATE_DIR")" \
        -I "$TMP" -L "$TMP" -main-file "$TMP/$2" 2>&1)
    if [ "$actual" = "$4" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        echo "  expected:"; printf '%s\n' "$4" | sed 's/^/    /'
        echo "  actual:";   printf '%s\n' "$actual" | sed 's/^/    /'
        FAILS=$((FAILS + 1))
    fi
}

run_repl "startup-import" imports.bn \
"testing.Println(hv.V, hv.GetV(), hv.GetW(), gv.Read[int](), Count)
" \
"$BANNER
> 2 2 3 2 50
> "

run_repl "prompt-import" plain.bn \
'import "pkg/hv"
testing.Println(hv.V, hv.GetV(), hv.GetW())
' \
"$BANNER
> package pkg/hv loaded
> 2 2 3
> "

run_repl "prompt-import-faults" plain.bn \
'import ("pkg/usesbad"; "pkg/hv")
testing.Println(hv.V)
func f() int { return 7 }
testing.Println(f())
' \
"$BANNER
> package pkg/hv loaded
initialization of package pkg/bad faulted: runtime error: nil pointer dereference
error: package not imported (it, or a package it imports, failed type-checking or initialization): pkg/usesbad
> 2
> > 7
> "

actual=$(printf '' | "$BNI_BIN" --repl \
    -I "$("$PATHS" --iface --base "$BINATE_DIR")" -L "$("$PATHS" --impl --base "$BINATE_DIR")" \
    -I "$TMP" -L "$TMP" -main-file "$TMP/badinit.bn" 2>&1)
if printf '%s' "$actual" | grep -qF "package initialization faulted" && ! printf '%s' "$actual" | grep -qF "$BANNER"; then
    echo "PASS: startup-faults"
else
    echo "FAIL: startup-faults"
    echo "  expected: a setup error naming the initialization fault, no session"
    echo "  actual:"; printf '%s\n' "$actual" | sed 's/^/    /'
    FAILS=$((FAILS + 1))
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
