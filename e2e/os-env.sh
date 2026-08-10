#!/bin/sh
# e2e/os-env.sh — End-to-end check of pkg/std/os's Env() against the real process
# environment, on BOTH execution paths: a compiled native binary, and the same
# program interpreted by cmd/bni.
#
# os.Env() returns the process environment as @[]readonly @[]readonly char, one
# "NAME=value" string per entry (POSIX environ order).  The hosted Binate entry
# (pkg/builtins/startup._entry, the c_export'd `main`) captures the real envp — C
# main's third argument — at process start and COPIES each string (unlike argv,
# which it borrows: environ is mutable, so a borrow could dangle after
# setenv/putenv).  The bytecode VM path needs no separate install: os is injected
# host-native, so an interpreted program shares cmd/bni's own `env` cell, which
# cmd/bni's _entry already populated from the environment it was launched with.
#
# This exports a known variable (BINATE_TEST_ENV) into the child's environment,
# then compiles/interprets a fixture that (a) asserts os.Env() is non-empty and
# (b) prints the matching "BINATE_TEST_ENV=<value>" entry, and checks that the
# copied snapshot surfaces it exactly on both paths.
#
# Compiling needs a gen1 (checkout-source) compiler, NOT the BUILDER directly:
# os.Env()/SetEnv postdate the pinned BUILDER's frozen stdlib bundle.  Uses the
# standard BUILDER -> gen1 -> build-with-checkout-paths shape.
#
# Exit 0 on full pass; non-zero with a diff on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo "SKIP: os-env unsupported on $(uname -s)"; exit 0 ;;
esac

TMP="$(mktemp -d /tmp/binate_e2e_os_env.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"

# Fixture: assert os.Env() is non-empty, then print the "BINATE_TEST_ENV=<value>"
# entry (whole "NAME=value" string) for any entry whose key is BINATE_TEST_ENV.
# Reads env[i] element-by-element (a readonly-qualified element can't be passed to
# a raw-slice parameter, so the prefix check is inline).
cat > "$TMP/os_env.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"
import "pkg/std/os"

func main() {
	var env @[]readonly @[]readonly char = os.Env()
	if len(env) > 0 {
		testing.Println("env-nonempty")
	} else {
		testing.Println("env-empty")
	}
	var key *[]readonly char = "BINATE_TEST_ENV="
	for i := 0; i < len(env); i++ {
		if len(env[i]) >= len(key) {
			var match bool = true
			for j := 0; j < len(key); j++ {
				if env[i][j] != key[j] {
					match = false
				}
			}
			if match {
				testing.Print("found=")
				testing.Print(env[i])
				testing.Println("")
			}
		}
	}
}
EOF

# ----- Resolve a gen1 (native, checkout-source) compiler. -----
# resolve-gen1.sh builds+caches gen1 (the BUILDER compiling checkout cmd/bnc) once
# per tree state, so a full e2e run builds it once and shares it across tests
# rather than each test rebuilding its own.
GEN1_BNC="$("$BINATE_DIR/scripts/resolve-gen1.sh")"

# Common checkout -I/-L (fixture and cmd/bni both link against the current stdlib).
CK_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CK_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
CK_RT="$BINATE_DIR/runtime/binate_runtime.c"

# ----- Build the fixture (native) and cmd/bni (native), both via gen1. -----
ENV_BIN="$TMP/os_env-bin"
compile_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$ENV_BIN" "$TMP/os_env.bn" 2>&1) || true
if [ ! -x "$ENV_BIN" ]; then
    echo "FAIL: Binate compile of the os.Env fixture failed" >&2
    echo "$compile_log" | sed 's/^/  /' >&2
    exit 1
fi
BNI_BIN="$TMP/bni-bin"
bni_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$BNI_BIN" "$BINATE_DIR/cmd/bni" 2>&1) || true
if [ ! -x "$BNI_BIN" ]; then
    echo "FAIL: could not build cmd/bni" >&2
    echo "$bni_log" | sed 's/^/  /' >&2
    exit 1
fi

PASSES=0
FAILS=0
FAIL_NAMES=""

check() {
    label="$1"
    expected="$2"
    actual="$3"
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

# The child inherits BINATE_TEST_ENV; the snapshot os.Env() takes at entry must
# surface it exactly (key + value, copied).  env-nonempty leads every run.
WITH_VAR="env-nonempty
found=BINATE_TEST_ENV=hello123"

# (a) compiled native binary: _entry captured envp and copied the snapshot.
check "compiled/with-var" "$WITH_VAR" \
    "$(BINATE_TEST_ENV=hello123 "$ENV_BIN" 2>&1)"

# (b) cmd/bni interpreting the fixture: os is injected host-native, so the program
# shares cmd/bni's env cell (populated by cmd/bni's own _entry) — no os.SetEnv
# needed, since env (unlike argv) is not split at `--`.
check "interp/with-var" "$WITH_VAR" \
    "$(BINATE_TEST_ENV=hello123 "$BNI_BIN" -I "$CK_I" -L "$CK_L" "$TMP/os_env.bn" 2>&1)"

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
