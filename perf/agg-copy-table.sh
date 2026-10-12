#!/bin/sh
# perf/agg-copy-table.sh — count the full-size copies and zero-fills each shape of
# perf/agg-copy-table/probe.bn compiles to: a by-value aggregate passed, returned,
# stored into a local or a field.  A static count, per function, for the native
# aa64 backend (the disassembly's copy and zero-fill loops) and the LLVM backend
# for arm32 bare metal (the rt.MemCopy / rt.MemZero calls in the IR bnc emits,
# before clang, whose own inlining would blur the shapes; a by-value argument's
# copy into r0-r3 + stack is the C ABI's, made by LLVM's lowering of `byval`, and
# is not counted).  Both at -O2 -fno-inline, so each shape is measured alone.
#
# Usage: perf/agg-copy-table.sh <bnc>
#   <bnc>  the compiler to measure (scripts/build-bnc.sh -o <path> builds one from
#          the current tree); run on an arm64 host (the native column is aa64).
set -e
BNC=${1:?usage: perf/agg-copy-table.sh <bnc>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$ROOT/perf/agg-copy-table"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"
IH=$(scripts/binate-paths.sh --iface --base .)
LH=$(scripts/binate-paths.sh --impl --base .)
IB=$(scripts/binate-paths.sh --target arm32-baremetal --iface --base .)
LB=$(scripts/binate-paths.sh --target arm32-baremetal --impl --base .)
"$BNC" -O2 -fno-inline --backend native -I "$IH" -L "$LH" -o "$TMP/native" "$DIR/probe.bn"
OUT=$("$TMP/native")
if [ "$OUT" != "27 3 7" ]; then
	echo "agg-copy-table: the probe printed '$OUT', not '27 3 7'" >&2
	exit 1
fi
objdump -d --no-show-raw-insn "$TMP/native" > "$TMP/native.dis"
"$BNC" -O2 -fno-inline --emit-llvm --target arm32-baremetal -I "$IB" -L "$LB" "$DIR/probe.bn" > "$TMP/arm32.ll"
python3 "$DIR/count.py" "$TMP/native.dis" "$TMP/arm32.ll"
