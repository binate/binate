#!/bin/sh
# e2e/debug-info-lldb.sh — a `bnc -g` program debugs under lldb on macOS.
#
# On Mach-O the linker leaves the DWARF in the objects, the program only naming them,
# and bnc removes its objects after the link; so bnc gathers the debug info into
# prog.dSYM (dsymutil), where lldb finds it.  The program is built with bnc's default
# build directory, which is removed with its objects, so lldb can only be reading the
# bundle.  The checks:
#   - prog.dSYM exists;
#   - a breakpoint on a source line resolves to an address at that line.
#
# macOS only: lldb, dsymutil and the debug map are the Mach-O side.  An ELF link copies
# the DWARF into the program itself.
set -eu

BINATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(uname -s)" != Darwin ]; then
    echo "SKIP: the .dSYM and lldb checks are the macOS (Mach-O) side of -g"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_debug_info_lldb.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNC="$TMP/bnc"
if ! "$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" > "$TMP/build_bnc.log" 2>&1; then
    echo "FAIL: could not build bnc" >&2
    cat "$TMP/build_bnc.log" >&2
    exit 1
fi

# The LLVM backend names a module's one file <module>.bn, so the program is main.bn.
# Line 11 is add's first statement.
mkdir "$TMP/src"
cat > "$TMP/src/main.bn" <<'BN'
package "main"

import "pkg/std/os"

type Pair struct {
	a int
	b int
}

func add(first int, second int, p Pair) int {
	var sum int = first + second + p.a + p.b
	return sum * 2
}

func main() {
	var p Pair = Pair{a: 5, b: 6}
	os.Exit(add(1234, 4321, p) - 11132)
}
BN
LINE=11

IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
PROG="$TMP/prog"
if ! "$BNC" -g -I "$IFACE" -L "$IMPL" -o "$PROG" "$TMP/src/main.bn" > "$TMP/bnc.log" 2>&1; then
    echo "FAIL: bnc -g failed" >&2
    cat "$TMP/bnc.log" >&2
    exit 1
fi
if ! "$PROG"; then
    echo "FAIL: the -g program did not exit 0" >&2
    exit 1
fi
if [ ! -d "$PROG.dSYM" ]; then
    echo "FAIL: bnc -g made no $PROG.dSYM" >&2
    exit 1
fi

# Statically: the line breakpoint resolves at that line.
lldb -b -o "breakpoint set -f main.bn -l $LINE" "$PROG" > "$TMP/static.log" 2>&1 || true
if ! grep -q "at main.bn:$LINE" "$TMP/static.log"; then
    echo "FAIL: lldb did not resolve main.bn:$LINE from the program's debug info" >&2
    cat "$TMP/static.log" >&2
    exit 1
fi

echo "PASS: a bnc -g program debugs under lldb (prog.dSYM, line breakpoint)"
