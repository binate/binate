#!/bin/sh
# e2e/program-bn-init.sh — End-to-end test that a PROGRAM artifact (a `main`
# package with `func main`) exposes the well-known `bn_init` symbol, so a C host
# can initialize it and call its `#[c_export]` functions WITHOUT running main.
#
# `bn_init` is now emitted in every artifact, not just `--library` builds: a
# program's `bn_entry` is literally `bn_init(); main.main()` (spec abi/06 §6.7).
# Before that, an ordinary program had no `bn_init`, so a C host following the
# spec and calling `bn_init` against a program-shaped link got an undefined
# symbol.  This test builds a program to objects (`bnc -c`), archives them, and
# links a C driver that calls `bn_init` (twice) and two exports — never main.
#
# It proves three things: `bn_init` (and `bn_entry`) are defined external symbols
# in a program artifact; the C host's `bn_init` call runs the package inits; and
# the run-once guard holds (a second `bn_init()` does not re-run them — the
# counter stays 1).  The library legs (library-iface-assert.sh, ffi-export.sh)
# cover the `--library` side.
#
# The C driver's own `main` is what runs; the program's `_entry` (`#[c_export]`
# "main") member is never pulled from the archive, so there is no `main`
# collision.  The link uses dead-strip (`-dead_strip` on Mach-O,
# `--gc-sections` on ELF) so the unreferenced `rt.Alloc` — which pulls the
# aarch64 hand-asm `rt.MemZero` that `-c` does not emit — is dropped; the test
# program is allocation- and interface-free, so `bn_init` never allocates.
#
# Uses a gen1 bnc from current source.  Auto-discovered by
# .github/workflows/e2e-tests.yml on Linux + macOS; needs only a host C compiler
# (no cross-toolchain).  Exit 0 on pass.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

CLANG="${CLANG:-$(command -v clang || command -v cc || echo cc)}"
if ! command -v "$CLANG" >/dev/null 2>&1; then
    echo "SKIP: program-bn-init (no C compiler '$CLANG' available)"
    exit 0
fi

# Dead-strip flag: Mach-O (macOS) vs ELF (Linux et al).
case "$(uname -s)" in
    Darwin) GC_FLAG="-Wl,-dead_strip" ;;
    *)      GC_FLAG="-Wl,--gc-sections" ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_proginit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- build gen1 bnc from current source -----------------------------------
echo "Building gen1 bnc from current source..."
GEN1="$TMP/gen1-bnc"
gen1_log=$("$BINATE_DIR/scripts/build-bnc.sh" -o "$GEN1" 2>&1) || true
if [ ! -x "$GEN1" ]; then
    echo "FAIL: gen1 bnc build failed:"
    echo "$gen1_log" | tail -20
    exit 1
fi
IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

# --- the program: a `main` package with func main, two #[c_export] functions,
# and a package-init side effect (counter) — interface-free and
# allocation-free, so bn_init's BuildSatRegistry(nil) is a no-op.
mkdir -p "$TMP/prog"
cat > "$TMP/prog/main.bn" <<'EOF'
package "main"

var counter int // bss (no initializer)

// bumpCounter runs once, from main.__init, which bn_init dispatches.
func bumpCounter() bool {
	counter = counter + 1
	return true
}

var _ bool = bumpCounter()

#[c_export("prog_add")]
func Add(a int32, b int32) int32 {
	return a + b
}

#[c_export("prog_counter")]
func Counter() int32 {
	return cast(int32, counter)
}

func main() {
	// A normal run reaches here via bn_entry; the C host never calls it.
}
EOF

# --- C driver: init once (twice, to prove idempotency), then call the exports,
# without ever running main.
cat > "$TMP/driver.c" <<'EOF'
#include <stdio.h>
extern void bn_init(void);
extern int prog_add(int, int);
extern int prog_counter(void);
int main(void) {
    bn_init();                 /* run every package __init once */
    bn_init();                 /* idempotent: run-once guard must NOT re-run */
    int s = prog_add(40, 2);   /* 42 */
    int c = prog_counter();    /* 1 -> init ran exactly once */
    printf("%d %d\n", s, c);
    return (s == 42 && c == 1) ? 0 : 1;
}
EOF

PASSES=0
FAILS=0
SKIPS=0
FAIL_NAMES=""

# check_backend <label> <extra-bnc-flags> <required>
#   Compile the program to objects with the given backend, archive them, link
#   the C driver, run, and check the "42 1" result.  required=1 -> a compile
#   failure is a hard FAIL; required=0 (native) -> producing no objects SKIPs
#   (the host native backend may not cover this program), but a produced-but-
#   wrong result FAILs.
check_backend() {
    label="$1"; extra="$2"; required="$3"
    work="$TMP/$label"
    mkdir -p "$work"
    echo "[$label] compiling program to objects..."
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" $extra \
            --build-dir "$work" -c "$TMP/prog/main.bn" >"$work/objs.txt" 2>"$work/c.err" \
            || [ ! -s "$work/objs.txt" ]; then
        if [ "$required" -eq 1 ]; then
            echo "FAIL: $label: -c produced no objects"
            tail -8 "$work/c.err" | sed 's/^/    /'
            FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        else
            echo "SKIP: $label: native -c unavailable for this host (no objects)"
            SKIPS=$((SKIPS + 1))
        fi
        return
    fi
    # The program artifact must DEFINE bn_init (external) — the property this
    # test exists for.  nm's symbol prefix differs by platform ('_bn_init' on
    # Mach-O, 'bn_init' on ELF), so match either.
    if ! nm "$work"/*.o 2>/dev/null | grep -Eq ' [TS] _?bn_init$'; then
        echo "FAIL: $label: program objects do not define an external bn_init"
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        return
    fi
    # shellcheck disable=SC2046
    ar rcs "$work/prog.a" $(cat "$work/objs.txt")
    if ! "$CLANG" -w $GC_FLAG "$TMP/driver.c" "$work/prog.a" -o "$work/run" \
            2>"$work/link.err" || [ ! -x "$work/run" ]; then
        echo "FAIL: $label: link of C driver + program archive failed"
        head -8 "$work/link.err" | sed 's/^/    /'
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
        return
    fi
    out="$("$work/run" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "42 1" ]; then
        echo "PASS: $label: C host called bn_init + exports on a program (no main run): '$out'"
        PASSES=$((PASSES + 1))
    else
        echo "FAIL: $label: result '$out' (rc=$rc, want '42 1' — counter!=1 means inits ran wrong)"
        FAILS=$((FAILS + 1)); FAIL_NAMES="$FAIL_NAMES $label"
    fi
}

# LLVM is required (the fix lives in backend-neutral IR-gen, but LLVM is the
# always-available backend); native self-skips when the host backend can't emit
# the program's objects, but must pass when it runs.
check_backend "llvm"   ""                 1
check_backend "native" "--backend native" 0

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed, $SKIPS skipped ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
