#!/bin/sh
# e2e/c-global-environ.sh — Adversarially verify the __c_global intrinsic against
# the platform C runtime, using the system C compiler as the authoritative
# source.  __c_global("environ", **char) recovers the ADDRESS of the C global
# `environ` as a raw ***char; *it is the current **char (a null-terminated array
# of *char C strings).  We:
#   1. Compile + run a tiny C program that reads `environ` and prints the entry
#      COUNT and a byte CHECKSUM over all entries — the ground truth.
#   2. Compile + run a Binate program that reads the SAME `environ` via
#      __c_global and prints the same two numbers.
#   3. diff.  Any mismatch means __c_global recovered the wrong address or
#      mis-dereferences — a fail.
#
# Both processes inherit this script's environment, so `environ` is identical;
# the checksum (not just the count) pins that the FULL contents agree, so a
# wrong-but-nonempty address can't pass.
#
# Compiled-mode only (the bytecode VM does no FFI); this script only exercises
# the compiled path.  Exit 0 on agreement, non-zero with a diff on mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo "SKIP: c-global-environ unsupported on $(uname -s)"; exit 0 ;;
esac

CC="${CC:-$(command -v cc || command -v clang || command -v gcc || echo cc)}"
TMP="$(mktemp -d /tmp/binate_e2e_cglobal.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Run both processes under a FIXED, identical environment (via `env -i`) so
# `environ` is deterministic.  The inherited environment is unusable as-is: the
# shell sets volatile per-command vars like `_` (the last command's path), so
# cref and the Binate probe would otherwise see different `environ` contents —
# same count, diverging checksum.  Values are single words (no spaces) so the
# unquoted expansion below word-splits into exactly one KEY=VAL per entry; an
# empty value and a non-ASCII value add coverage for the byte checksum.
FIXED_ENV="CGE_A=alpha CGE_B= CGE_LONG=abcdefghijklmnopqrstuvwxyz0123456789 CGE_UTF=cafe_ready"

# ---- 1. Ground truth: real `environ`, via the system C compiler.
cat > "$TMP/cref.c" <<'EOF'
#include <stdio.h>
extern char **environ;
int main(void) {
    int count = 0;
    long sum = 0;
    for (char **e = environ; *e != 0; e++) {
        count++;
        for (unsigned char *p = (unsigned char *)*e; *p != 0; p++) sum += *p;
    }
    printf("%d\n%ld\n", count, sum);
    return 0;
}
EOF
"$CC" -o "$TMP/cref" "$TMP/cref.c" || { echo "FAIL: C compile failed" >&2; exit 1; }
# shellcheck disable=SC2086  # deliberate word-splitting of FIXED_ENV
env -i $FIXED_ENV "$TMP/cref" > "$TMP/truth.txt"

# ---- 2. The same, in Binate via __c_global.
cat > "$TMP/eprobe.bn" <<'EOF'
package "main"

import "pkg/builtins/testing"

func main() {
	var pp ***char = __c_global("environ", **char)
	var env **char = *pp
	var count int = 0
	var sum int = 0
	for present(unsafe_index(env, count)) {
		var s *char = unsafe_index(env, count)
		var j int = 0
		for unsafe_index(s, j) != cast(char, 0) {
			sum = sum + cast(int, unsafe_index(s, j))
			j = j + 1
		}
		count = count + 1
	}
	testing.Println(count)
	testing.Println(sum)
}
EOF

# Build gen1 (the current tree's cmd/bnc, built fresh from source), NOT the
# pinned BUILDER: __c_global postdates BUILDER_VERSION, so the prebuilt BUILDER
# cannot compile a program that uses it.
GEN1="$TMP/gen1"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: building the gen1 compiler failed" >&2
    echo "$gen1_log" | tail -8 | sed 's/^/  /' >&2
    exit 1
fi
BNC_BIN="$TMP/eprobe"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"
bnc_log=$("$GEN1" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    --runtime "$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")" \
    --build-dir "$BUILD_DIR" -o "$BNC_BIN" "$TMP/eprobe.bn" 2>&1) || true
if [ ! -x "$BNC_BIN" ]; then
    echo "FAIL: Binate compile of the __c_global probe failed" >&2
    echo "$bnc_log" | sed 's/^/  /' >&2
    exit 1
fi
# shellcheck disable=SC2086  # deliberate word-splitting of FIXED_ENV
env -i $FIXED_ENV "$BNC_BIN" > "$TMP/binate.txt"

# ---- 3. Compare.
if ! diff "$TMP/truth.txt" "$TMP/binate.txt" > "$TMP/diff.txt"; then
    echo "FAIL: __c_global(environ) disagrees with C environ on $(uname -s) $(uname -m)" >&2
    echo "  (< real environ   > __c_global)" >&2
    echo "  fields: entry count, then byte checksum over all entries" >&2
    sed 's/^/  /' "$TMP/diff.txt" >&2
    exit 1
fi

echo "PASS: __c_global(environ) matches C environ on $(uname -s) $(uname -m) (count + checksum)"
