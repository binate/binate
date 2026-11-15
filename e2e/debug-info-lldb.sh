#!/bin/sh
# e2e/debug-info-lldb.sh — a `bnc -g` program debugs under lldb on macOS.
#
# On Mach-O the linker leaves the DWARF in the objects, the program only naming them,
# and bnc removes its objects after the link; so bnc gathers the debug info into
# prog.dSYM (dsymutil), where lldb finds it.  The program is built with bnc's default
# build directory, which is removed with its objects, so lldb can only be reading the
# bundle.  The checks:
#   - prog.dSYM exists;
#   - a breakpoint on a source line resolves to an address at that line;
#   - stopped on the function's first statement's line, and stopped by a breakpoint on
#     the function (by its linkage name: lldb finds no function by the debug name
#     `main.add`), lldb reads the function's parameters, a struct one included: the
#     setup of their frame slots comes before the first location in the function.
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

# Running: stopped at add's first statement, or on add itself, the parameters hold
# their arguments.
for bp in "-f main.bn -l $LINE" "-n bn_F1_4_main1_3_add"; do
    lldb -b -o "breakpoint set $bp" -o run -o "frame variable first second p" -o kill \
            "$PROG" > "$TMP/run.log" 2>&1 || true
    if ! grep -q "first = 1234" "$TMP/run.log" || ! grep -q "second = 4321" "$TMP/run.log" ||
            ! grep -q "a = 5, b = 6" "$TMP/run.log"; then
        echo "FAIL: stopped by breakpoint set $bp, lldb did not read add's parameters" >&2
        cat "$TMP/run.log" >&2
        exit 1
    fi
done

echo "PASS: a bnc -g program debugs under lldb (prog.dSYM, line breakpoint, parameters)"
