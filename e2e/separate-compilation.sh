#!/bin/sh
# e2e/separate-compilation.sh — End-to-end test that bnc supports SEPARATE
# COMPILATION: compiling each package of a program in its OWN bnc invocation
# (`--pkg`), then linking the independently-produced objects into a working
# binary.  This is the "separate compilation per package" the toolchain's
# architecture promises (explorations/claude-plan-3.md: "Each package compiles
# to its own .ll -> .o, then all are linked together ... enables partial
# recompilation") — but which nothing had ever exercised end-to-end.
#
# It builds a NONTRIVIAL real target — cmd/bnas (the assembler, ~21 packages,
# including all four implicit runtime packages) — ENTIRELY via separate
# compilation, and proves the result is functionally identical to a normally
# (whole-program) compiled bnas:
#   1. `bnc --list-deps cmd/bnas`  -> the full ordered dependency set.
#   2. `bnc --pkg <P>` for EACH package, in its own invocation -> one .o each.
#   3. `bnc -c cmd/bnas`           -> main.o (the entry module; its dep .o's are
#                                     discarded — we link the --pkg ones).
#   4. link main.o + all the separately-built .o's + runtime -> bnas_sep.
#   5. build a canonical bnas the normal whole-program way    -> bnas_canon.
#   6. assert bnas_sep and bnas_canon AGREE: identical --version, and assembling
#      a data fixture .s yields BYTE-IDENTICAL objects (exercises the real
#      assembler across the separately-compiled binary).
#
# Guards the fix that made this work at all: `--pkg` used to skip loading the
# implicit runtime packages (rt / bootstrap / reflect / lang), so a package that
# emitted a runtime-helper call — e.g. `rt.BoundsCheck` from ANY slice/array
# index — referenced an undeclared symbol and clang rejected the IR
# (`use of undefined value`).  Separate compilation was thus dead-on-arrival for
# essentially every real package (pure-arithmetic leaves happened to survive).
#
# Default: a gen1 bnc built from the current source.  `--builder` also runs the
# BUILDER bnc as a sanity-check of the test harness, but the shipped BUILDER
# predates both `--list-deps` and the `--pkg` fix, so it reports SKIP until the
# next BUILDER bump.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

WITH_BUILDER=0
for arg in "$@"; do
    case "$arg" in
        --builder) WITH_BUILDER=1 ;;
        *) echo "usage: $0 [--builder]" >&2; exit 2 ;;
    esac
done

CLANG="${CLANG:-$(command -v clang || echo clang)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_sepc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The real, nontrivial target compiled via separate compilation.
TARGET="cmd/bnas"

# A data-only assembly fixture (avoids bnas's instruction dialect — just the
# directive/data-emission + object-writer path) used to prove the separately
# built assembler produces byte-identical output to the canonical one.
FIXTURE="$TMP/fixture.s"
cat > "$FIXTURE" <<'EOF'
.arch aarch64
.section data
.global sepc_fixture
sepc_fixture:
	.uint32 42
	.asciz "separate-compilation-ok"
	.uint64 1311768467463790320
	.int8 1, 2, 3, 4
EOF

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""

pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }
fail() {
    echo "FAIL: $1"
    # Capture the label (first word of $1) BEFORE shift — after shift $1 is the
    # first detail line, and for a single-arg call $1 is unset (which aborts
    # under `set -u` in dash).
    FAIL_NAMES="$FAIL_NAMES ${1%% *}"
    shift
    for line in "$@"; do echo "  $line"; done
    FAILS=$((FAILS + 1))
}

# run_sepc <label> <bnc> <iface> <impl> <runtime>
#   iface/impl/runtime must be the search paths + runtime object matching <bnc>
#   (the current tree for gen1, the frozen bundle for the BUILDER).
run_sepc() {
    label="$1"; bnc="$2"; iface="$3"; impl="$4"; runtime="$5"
    work="$TMP/$label"
    mkdir -p "$work/sep" "$work/wp"

    # --- 1. the full dependency set --------------------------------------
    deps=$("$bnc" -I "$iface" -L "$impl" --runtime "$runtime" --list-deps "$TARGET" 2>"$work/listdeps.err")
    ld_rc=$?
    # bnc prints loader errors to STDOUT (the same stream as the dep list — see
    # cmd/bnc/main.bn's ListDeps path), and signals a failed load with a non-zero
    # exit.  Guard on BOTH so a failure surfaces the real error instead of feeding
    # a polluted list (e.g. an `error:` line) into the per-package loop below as a
    # bogus "package".
    if [ "$ld_rc" -ne 0 ] || [ -z "$deps" ]; then
        fail "$label: --list-deps failed (rc=$ld_rc)" \
             "stdout: $(printf '%s\n' "$deps" | head -5)" \
             "stderr: $(head -3 "$work/listdeps.err")"
        return
    fi
    ndeps=$(printf '%s\n' "$deps" | grep -c .)

    # --- 2. compile EACH dependency in its OWN bnc invocation ------------
    n=0
    for p in $deps; do
        n=$((n + 1))
        d="$work/sep/p$n"
        mkdir -p "$d"
        if ! "$bnc" -I "$iface" -L "$impl" --runtime "$runtime" \
                --build-dir "$d" --pkg "$p" >"$d/log" 2>&1 \
                || [ -z "$(ls "$d"/*.o 2>/dev/null)" ]; then
            fail "$label: separate compile of '$p' produced no object" \
                 "$(tail -3 "$d/log")"
            return
        fi
    done

    # --- 3. the entry module (main.o) -----------------------------------
    if ! "$bnc" -I "$iface" -L "$impl" --runtime "$runtime" \
            --build-dir "$work/wp" -c "$TARGET" >"$work/wp/log" 2>&1 \
            || [ ! -f "$work/wp/main.o" ]; then
        fail "$label: could not compile main.o (-c $TARGET)" "$(tail -3 "$work/wp/log")"
        return
    fi

    # --- 4. link the independently-built objects into a binary ----------
    sep_objs=$(find "$work/sep" -name '*.o' | tr '\n' ' ')
    bnas_sep="$work/bnas_sep"
    if ! "$CLANG" -w -o "$bnas_sep" "$work/wp/main.o" $sep_objs "$runtime" 2>"$work/link.err" \
            || [ ! -x "$bnas_sep" ]; then
        fail "$label: link of separately-compiled objects failed" "$(head -4 "$work/link.err")"
        return
    fi

    # --- 5. a canonical (whole-program) build for comparison ------------
    bnas_canon="$work/bnas_canon"
    if ! "$bnc" -I "$iface" -L "$impl" --runtime "$runtime" \
            --build-dir "$work/wp" -o "$bnas_canon" "$TARGET" >"$work/canon.log" 2>&1 \
            || [ ! -x "$bnas_canon" ]; then
        fail "$label: canonical build failed (test harness problem)" "$(tail -3 "$work/canon.log")"
        return
    fi

    # --- 6a. the separately-built binary runs and matches --version -----
    v_sep=$("$bnas_sep" --version 2>&1) || true
    v_canon=$("$bnas_canon" --version 2>&1) || true
    if [ -z "$v_sep" ] || [ "$v_sep" != "$v_canon" ]; then
        fail "$label: --version mismatch (sep='$v_sep' canon='$v_canon')"
        return
    fi

    # --- 6b. it assembles a fixture to byte-identical output ------------
    if ! "$bnas_sep" -o "$work/fix_sep.o" "$FIXTURE" 2>"$work/asm_sep.err" \
            || [ ! -f "$work/fix_sep.o" ]; then
        fail "$label: separately-built bnas failed to assemble the fixture" \
             "$(head -3 "$work/asm_sep.err")"
        return
    fi
    "$bnas_canon" -o "$work/fix_canon.o" "$FIXTURE" 2>/dev/null || true
    if ! cmp -s "$work/fix_sep.o" "$work/fix_canon.o"; then
        fail "$label: separately-built bnas assembles DIFFERENTLY from canonical" \
             "sep and canonical objects differ for the same input"
        return
    fi

    pass "$label ($ndeps packages separately compiled + linked; bnas $v_sep; assembly byte-identical)"
}

# ---- gen1 (default, required) --------------------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed:"
    echo "$gen1_log" | tail -20
    exit 1
fi
GEN1_IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
GEN1_IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
GEN1_RT="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BINATE_DIR")"
run_sepc "gen1" "$GEN1" "$GEN1_IFACE" "$GEN1_IMPL" "$GEN1_RT"

# ---- BUILDER (opt-in sanity check) ---------------------------------------
if [ "$WITH_BUILDER" -eq 1 ]; then
    BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh" 2>/dev/null)" || true
    BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib 2>/dev/null)" || true
    if [ -z "${BUILDER:-}" ] || [ ! -x "$BUILDER" ]; then
        skip "builder (could not resolve a BUILDER bnc)"
    elif ! "$BUILDER" --list-deps "$TARGET" >/dev/null 2>&1; then
        # The shipped BUILDER predates --list-deps (and the --pkg rt-load fix);
        # it cannot drive separate compilation until it is bumped past them.
        skip "builder ($("$BUILDER" --version 2>&1 | head -1) predates --list-deps / the --pkg fix; flips to a real check after the next BUILDER bump)"
    else
        BLD_IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB")"
        BLD_IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB")"
        BLD_RT="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"
        run_sepc "builder" "$BUILDER" "$BLD_IFACE" "$BLD_IMPL" "$BLD_RT"
    fi
fi

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
