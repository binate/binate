#!/bin/sh
# e2e/satentry-retention.sh — End-to-end test that the whole-program SatEntry
# root retains every package's `__satentry.<T,J>` nodes across the linker's
# dead-strip (RTTI Slice 3, plan-type-assertions-execution.md §U.4).
#
# `impl T : J` emits a weak per-`(T,J)` `__satentry` record, but nothing READS it
# until the Phase-5 interface-assertion reader — so without a live root the
# linker would dead-strip every one, leaving the reader an empty registry.  bnc
# therefore emits a compiler-synthesized `{ptr,len}[]` root over each package's
# `_pkg_satentries` array (gathered `ldr.Order ∪ main`) and roots it from
# `__entry`: LLVM pins it in `@llvm.used`; the native backends reference it with a
# real LEA/ADRP reloc.  This test compiles a program with an `impl` and asserts,
# via `nm`, that the root AND the `__satentry` nodes — BOTH the program's OWN and
# a cross-package DEPENDENCY's (`builtins/lang`, always pulled in transitively;
# exercises the M4 cross-object extern-data path) — survive into the linked
# binary.  It checks the DEFAULT LLVM backend and the host `--backend native`.
#
# The root is inert until Slice 5 wires the reader, so a retention regression is
# INVISIBLE to conformance (an unread root changes no program output) — only a
# symbol-table check like this one catches it.
#
# Exit 0 on pass; non-zero with diagnostics on failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

NM="${NM:-$(command -v nm || echo nm)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_satroot.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASSES=0
FAILS=0
FAIL_NAMES=""
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
fail() {
    echo "FAIL: $1"
    FAIL_NAMES="$FAIL_NAMES ${1%% *}"
    shift
    for line in "$@"; do echo "  $line"; done
    FAILS=$((FAILS + 1))
}

# A single-file program with an interface + impl in package main.  Constructing
# and dispatching through the interface value forces the (Thing, Greeter) impl —
# and thus its `__satentry` — to be emitted; `builtins/lang`'s satentries ride in
# transitively via the runtime.
SRC="$TMP/prog.bn"
cat > "$SRC" <<'EOF'
package "main"

import "pkg/builtins/testing"

interface Greeter {
	greet() int
}

type Thing struct {
	x int
}

func (t *Thing) greet() int {
	return t.x
}

impl *Thing : Greeter

func main() {
	var t Thing
	t.x = 42
	var g *Greeter = &t
	testing.Println(g.greet())
}
EOF

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

# check_retention <label> <extra-bnc-flags...>
#   Compile $SRC, run it (expect "42"), and assert the root + own/dependency
#   __satentry nodes survive dead-strip in the linked binary.
check_retention() {
    label="$1"; shift
    bin="$TMP/prog_$label"
    bd="$TMP/bd_$label"
    mkdir -p "$bd"
    if ! "$GEN1" -I "$IFACE" -L "$IMPL" --build-dir "$bd" "$@" \
            -o "$bin" "$SRC" >"$TMP/compile_$label.log" 2>&1; then
        fail "$label compile/link failed" "$(tail -5 "$TMP/compile_$label.log")"
        return
    fi
    out="$("$bin" 2>&1)"
    if [ "$out" != "42" ]; then
        fail "$label wrong runtime output" "expected '42', got '$out'"
        return
    fi
    syms="$("$NM" -a "$bin" 2>/dev/null)"
    # The synthesized root header must survive (it is the retention anchor).
    if ! printf '%s\n' "$syms" | grep -q 'satentry_root'; then
        fail "$label root symbol dead-stripped" "no *_satentry_root in nm output"
        return
    fi
    # The program's OWN impl node (Thing : Greeter) must survive.
    if ! printf '%s\n' "$syms" | grep -q 'satentry.*Thing'; then
        fail "$label own __satentry dead-stripped" "no Thing __satentry in nm output"
        return
    fi
    # A cross-package DEPENDENCY node (builtins/lang) must survive — this is the
    # M4 cross-object extern-data path (the root references another object's
    # `_pkg_satentries`, forcing the linker to retain it).
    if ! printf '%s\n' "$syms" | grep -q 'satentry.*builtins4_lang'; then
        fail "$label dependency __satentry dead-stripped" \
            "no builtins/lang __satentry retained via the root's dep path"
        return
    fi
    node_count="$(printf '%s\n' "$syms" | grep -c '__satentry\.')"
    pass "$label (root + $node_count __satentry nodes survive dead-strip)"
}

check_retention "llvm"                 # default backend (deps + main via LLVM)
check_retention "native" --backend native  # host native backend (aarch64 / x86-64)

echo ""
echo "=== Summary: $PASSES passed, $FAILS failed ==="
if [ "$FAILS" -ne 0 ]; then
    echo "Failed:$FAIL_NAMES"
    exit 1
fi
exit 0
