#!/bin/sh
# e2e/shebang-exec.sh — End-to-end check that a chmod +x'd `.bn` carrying a `#!`
# shebang runs DIRECTLY as `./script.bn args…` and receives its command-line
# arguments, exercising the whole shebang chain end to end:
#   - the kernel reads the `#!` line and invokes the interpreter (exec-bit + `#!`),
#   - bni takes the kernel-appended script path as the implicit main package and
#     hands every following arg to the program (after `--`, positionals are the
#     program's argv, not bni flags — even flag-looking ones),
#   - bni's LEXER skips the `#!` line (spec lex.shebang) so the shebang'd source
#     still parses,
#   - and os.Args() surfaces [<script>, args…] to the program.
#
# Harness note: bni has no default/built-in stdlib location — it resolves packages
# from the script's directory or an explicit -I/-L (cmd/bni resolveRoot), so a
# script importing pkg/std/os needs the checkout's stdlib search paths on the
# shebang: `#!/usr/bin/env -S <bni> -I <iface> -L <impl> --`.  The trailing `--`
# is the LAST word: `-S` splits the words into argv and the kernel appends the
# script path after `--`, so the script (and even a script named like a flag)
# lands as a positional — the implicit main — and its args follow.  This is the
# spec's own shebang form (§17.3.1) —
# `env` is a binary and its `-S` splits the remaining words into argv, working
# around the kernel's single-argument shebang limit; a deployed bni that shipped
# its stdlib would need no -I/-L.  (The shebang interpreter MUST be a binary —
# `env`/`bni` are — a shell-script wrapper would hit the kernel's no-nested-shebang
# rule.)  e2e/ has no exec-bit precedent (other e2e tests invoke a built binary by
# path); this is that new pattern.  It stays OUT of the conformance runner (which
# only dispatches .bn files through bnc/bni and has no exec-bit notion).
#
# Compiling cmd/bni needs a gen1 (checkout-source) compiler, NOT the BUILDER
# directly: os.Args()/-main-file postdate the pinned BUILDER's frozen bundle.  Standard
# BUILDER -> gen1 -> build-with-checkout-paths shape (mirrors e2e/os-args.sh).
#
# Exit 0 on pass; non-zero with a diff on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo "SKIP: shebang-exec unsupported on $(uname -s)"; exit 0 ;;
esac

# A SHORT tmp dir: the shebang line embeds several $TMP-relative paths and the
# kernel caps its length (Linux ~256 bytes), so keep the base tiny.
TMP="$(mktemp -d /tmp/bnsh.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# ----- Build gen1 (a native, checkout-source compiler). -----
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
GEN1_DIR="$BUILD_DIR/gen1"
GEN1_BNC="$GEN1_DIR/bnc"
mkdir -p "$GEN1_DIR/build"
# Transitional Linux gen1-link shim (BUILDER bnc-0.0.14 emits the iv-dispatch
# thunks STRONG); accept the ODR-identical dups.  Remove at BUILDER >= bnc-0.0.15.
# Full rationale: scripts/lib/build-compilers.sh build_gen1 + claude-todo.
gen1_dupthunk_flag=""
[ "$(uname -s)" = Linux ] && gen1_dupthunk_flag="--cflag -Wl,--allow-multiple-definition"
gen1_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR" --prepend "$BINATE_DIR/ifaces/toolchain")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --build-dir "$GEN1_DIR/build" \
    $gen1_dupthunk_flag \
    -o "$GEN1_BNC" \
    "$BINATE_DIR/cmd/bnc" 2>&1)
if [ ! -x "$GEN1_BNC" ]; then
    echo "FAIL: gen1 build failed:" >&2
    echo "$gen1_log" | sed 's/^/  /' >&2
    exit 1
fi

# Checkout -I/-L/runtime (cmd/bni and the fixture link the current stdlib).
CK_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CK_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# ----- Build cmd/bni (native) via gen1. -----
BNI_BIN="$TMP/bni"
bni_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" \
    --build-dir "$BUILD_DIR" -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1) || true
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: could not build cmd/bni" >&2
    echo "$bni_log" | sed 's/^/  /' >&2
    exit 1
fi

# ----- Shorten the -I/-L search paths for the shebang line.  The real checkout
# paths (colon-joined, several dirs each) far exceed the kernel's shebang-line
# length cap (Linux ~256 bytes) when embedded twice in a `#!` line.  Symlink each
# search-path component to a 1-char name under $TMP and rebuild short colon-joined
# lists, so the `#!` line stays small (~165 bytes) regardless of checkout depth. -----
shorten() {
    # $1 = colon-joined paths, $2 = symlink-name prefix.  Prints the short list.
    _out=""; _n=0; _oldifs=$IFS; IFS=:
    for _p in $1; do
        ln -s "$_p" "$TMP/$2$_n"
        if [ -n "$_out" ]; then _out="$_out:$TMP/$2$_n"; else _out="$TMP/$2$_n"; fi
        _n=$((_n + 1))
    done
    IFS=$_oldifs
    printf '%s' "$_out"
}
SI="$(shorten "$CK_I" i)"
SL="$(shorten "$CK_L" l)"

SHEBANG="#!/usr/bin/env -S $BNI_BIN -I $SI -L $SL --"
# Defensive: if a future path addition pushed the line past the kernel cap the
# kernel would SILENTLY TRUNCATE it (catastrophic), so fail loud instead.
if [ "${#SHEBANG}" -gt 250 ]; then
    echo "FAIL: shebang line too long (${#SHEBANG} > 250) — kernel would truncate it" >&2
    exit 1
fi

# ----- The executable script: the `env -S` shebang (naming bni + the shortened
# stdlib search paths + a trailing `--`), then a program that prints its argument count
# and each argument (Args()[1..]); element 0 is the path-dependent script name,
# skipped like e2e/os-args.sh. -----
SCRIPT="$TMP/greet.bn"
cat > "$SCRIPT" <<EOF
$SHEBANG
package "main"

import "pkg/builtins/testing"
import "pkg/std/os"

func main() {
	var a @[]readonly @[]readonly char = os.Args()
	testing.Println(len(a))
	for i := 1; i < len(a); i++ {
		testing.Print("[")
		testing.Print(a[i])
		testing.Println("]")
	}
}
EOF
chmod +x "$SCRIPT"

PASSES=0
FAILS=0
FAIL_NAMES=""

check() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $label"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label"
        echo "  expected:"; printf '%s\n' "$expected" | sed 's/^/    /'
        echo "  actual:";   printf '%s\n' "$actual"   | sed 's/^/    /'
        FAILS=$((FAILS + 1))
        FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# Run the script DIRECTLY (kernel shebang exec), with and without arguments.
WITH_ARGS="3
[one]
[two]"
NO_ARGS="1"

check "exec/with-args" "$WITH_ARGS" "$("$SCRIPT" one two 2>&1)"
check "exec/no-args"   "$NO_ARGS"   "$("$SCRIPT" 2>&1)"

# A FLAG-looking script argument must reach the program, not be swallowed by bni.
# The `--` in the shebang ends bni's flags, so `--flag` after the kernel-appended
# script path is a program arg (element of os.Args()), not `unknown flag: --flag`.
WITH_FLAG_ARG="3
[--flag]
[one]"
check "exec/flag-arg"  "$WITH_FLAG_ARG" "$("$SCRIPT" --flag one 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
