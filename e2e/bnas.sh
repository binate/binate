#!/bin/sh
# e2e/bnas.sh — End-to-end test of the bnas CLI contract (cmd/bnas/main.bn):
# a real assemble round-trip plus the tool-wiring the flags redesign
# (7902d5de7) left uncovered — --version banner, no-input usage, unknown flag,
# and the "multiple input files" rejection.  The generic flag-parsing behavior
# (unknown-flag/missing-value errors, positional handling) is unit-tested in
# pkg/stdx/flags; the actual assemble pipeline in pkg/binate/asm/assemble — this
# locks how cmd/bnas wires the two together end to end.
#
# Exit 0 on full pass; non-zero with per-case diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnas.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
ok() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
bad() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# ----- build bnas from the current tree -----
BNAS="$TMP/bnas"
if ! "$BINATE_DIR/scripts/build-bnas.sh" -o "$BNAS" > "$TMP/build.log" 2>&1; then
    echo "FAIL: could not build bnas" >&2
    cat "$TMP/build.log" >&2
    exit 1
fi

# ----- a minimal valid aarch64 input (the .arch directive picks the arch, so
#       no -arch flag is needed); the .o is not executed, only produced. -----
cat > "$TMP/min.s" <<'EOF'
.arch aarch64
.section text
.global _start
_start:
	nop
	ret
EOF

# ----- 1. a real assemble round-trip produces a non-empty object file -----
if "$BNAS" -o "$TMP/min.o" "$TMP/min.s" > "$TMP/a.log" 2>&1 && [ -s "$TMP/min.o" ]; then
    ok "assembles a minimal .s to a non-empty .o"
else
    bad "assemble round-trip failed: $(cat "$TMP/a.log")"
fi

# ----- 2. --version prints the bnas-<version> banner and exits 0 -----
vout="$("$BNAS" --version 2>&1)"
if [ $? -eq 0 ] && printf '%s\n' "$vout" | grep -q '^bnas-'; then
    ok "--version prints the bnas-<version> banner"
else
    bad "--version should print 'bnas-<version>' and exit 0 (got: $vout)"
fi

# ----- 3. no input file -> usage on stderr, non-zero -----
if "$BNAS" > /dev/null 2>"$TMP/e3.err"; then
    bad "no input file should exit non-zero"
elif grep -q 'usage: bnas' "$TMP/e3.err"; then
    ok "no input prints usage"
else
    bad "no-input should print usage: $(cat "$TMP/e3.err")"
fi

# ----- 4. an unknown flag is rejected and named on stderr -----
if "$BNAS" --bogus "$TMP/min.s" > /dev/null 2>"$TMP/e4.err"; then
    bad "an unknown flag should exit non-zero"
elif grep -q 'bogus' "$TMP/e4.err"; then
    ok "an unknown flag is rejected and named"
else
    bad "unknown-flag error should name the flag: $(cat "$TMP/e4.err")"
fi

# ----- 5. more than one input file is rejected -----
if "$BNAS" "$TMP/min.s" "$TMP/min.s" > /dev/null 2>"$TMP/e5.err"; then
    bad "two input files should exit non-zero"
elif grep -q 'multiple input files' "$TMP/e5.err"; then
    ok "multiple input files are rejected clearly"
else
    bad "multi-input error message unclear: $(cat "$TMP/e5.err")"
fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
[ "$FAILS" -eq 0 ] || exit 1
