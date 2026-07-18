#!/bin/sh
# e2e/bnfmt.sh — End-to-end test of bnfmt's multi-file handling: `-w` and
# `--check` accept any number of files and process each independently, `--check`
# names each unformatted file on stderr, and the default (stdout) mode still
# takes exactly one file.
#
# Exit 0 on full pass; non-zero with per-case diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnfmt.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
ok() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
bad() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# ----- build bnfmt from the current tree -----
BNFMT="$TMP/bnfmt"
if ! "$BINATE_DIR/scripts/build-bnfmt.sh" -o "$BNFMT" > "$TMP/build.log" 2>&1; then
    echo "FAIL: could not build bnfmt" >&2
    cat "$TMP/build.log" >&2
    exit 1
fi

# ----- fixtures: a canonical file (good.bn) and a not-formatted copy (bad.bn) -----
cat > "$TMP/src.bn" <<'EOF'
package "t"

func f() int {
	return 1
}
EOF
# The canonical form is whatever bnfmt emits (definitionally formatted).
"$BNFMT" "$TMP/src.bn" > "$TMP/good.bn"
# Not-formatted: canonical plus a trailing space on a code line (bnfmt strips it).
sed 's/return 1/return 1 /' "$TMP/good.bn" > "$TMP/bad.bn"

# ----- 1. --check on a single already-formatted file exits 0 -----
if "$BNFMT" --check "$TMP/good.bn"; then
    ok "check/single-formatted exits 0"
else
    bad "check/single-formatted should exit 0"
fi

# ----- 2. --check over [good, bad] exits non-zero and names ONLY the bad file --
errout="$("$BNFMT" --check "$TMP/good.bn" "$TMP/bad.bn" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "check/multi exits non-zero when one file is unformatted"
else
    bad "check/multi should exit non-zero (rc=$rc)"
fi
if printf '%s\n' "$errout" | grep -q 'bad\.bn'; then
    ok "check/multi names the unformatted file on stderr"
else
    bad "check/multi should name the unformatted file (stderr: $errout)"
fi
if printf '%s\n' "$errout" | grep -q 'good\.bn'; then
    bad "check/multi should NOT name the already-formatted file (stderr: $errout)"
else
    ok "check/multi does not name the already-formatted file"
fi

# ----- 3. -w over multiple files rewrites each to canonical form -----
cp "$TMP/bad.bn" "$TMP/bad1.bn"
cp "$TMP/bad.bn" "$TMP/bad2.bn"
"$BNFMT" -w "$TMP/bad1.bn" "$TMP/bad2.bn"
if "$BNFMT" --check "$TMP/bad1.bn" "$TMP/bad2.bn"; then
    ok "-w multi rewrote every file to canonical form"
else
    bad "-w multi should have formatted both files"
fi

# ----- 4. default (stdout) mode rejects more than one file -----
if "$BNFMT" "$TMP/good.bn" "$TMP/bad.bn" > /dev/null 2>"$TMP/e4.err"; then
    bad "stdout mode with two files should exit non-zero"
elif grep -q 'only one file' "$TMP/e4.err"; then
    ok "stdout mode with multiple files errors clearly"
else
    bad "stdout multi error message unclear: $(cat "$TMP/e4.err")"
fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
[ "$FAILS" -eq 0 ] || exit 1
