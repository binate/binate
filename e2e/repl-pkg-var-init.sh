#!/bin/sh
# e2e/repl-pkg-var-init.sh — An imported package's variables are initialized at
# the REPL as in a program: package initialization (prog.init.vars) runs before
# the package is used, whether it is imported by the session's main file or at
# the prompt.  A variable read directly, through the package's own function, or
# by a generic function's body monomorphized at the prompt (of a package that
# imports it, which the session does not), holds its initializer's value.
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
cat > "$TMP/imports.bn" <<'EOF2'
package "main"

import "pkg/builtins/testing"
import "pkg/gv"
import "pkg/hv"

func main() { testing.Println(hv.V) }
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
"testing.Println(hv.V, hv.GetV(), hv.GetW(), gv.Read[int]())
" \
"$BANNER
> 2 2 3 2
> "

run_repl "prompt-import" plain.bn \
'import "pkg/hv"
testing.Println(hv.V, hv.GetV(), hv.GetW())
' \
"$BANNER
> package pkg/hv loaded
> 2 2 3
> "

[ "$FAILS" -eq 0 ] || exit 1
exit 0
