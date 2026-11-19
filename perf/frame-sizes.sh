#!/bin/sh
# Measure native stack frames: compile a package with a given bnc for the native
# backend and print each named function's frame size (the stack adjustment its
# prologue makes), for one target.
#
# Usage: perf/frame-sizes.sh <bnc> <target> <pkg> <func>...
#   target: host | x86_64-darwin | arm32-linux | ... (a bnc --target key)
#   e.g. perf/frame-sizes.sh /tmp/bnc host pkg/binate/parser parseType parseStructType
# The package is read from the tree the script is in, or from $BINATE_ROOT.  The
# backend is native unless $BINATE_BACKEND names another (llvm), and $BINATE_FLAGS adds
# bnc flags (-O2).
#
# A function is matched by the end of its mangled symbol, `<len>_<name>` (Binate's
# mangling ends a name with its length and the name).  The frame is the sum of the
# stack adjustments at the top of the function: `sub sp, sp, #N` (aarch64, arm32;
# aarch64's `#N, lsl #12` is N * 4096) or `sub rsp, N` (x86-64), a large frame
# taking more than one.
set -e
[ $# -ge 4 ] || { sed -n '2,17p' "$0"; exit 2; }
BNC=$1; TARGET=$2; PKG=$3; shift 3
ROOT=${BINATE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
IFACE=$("$ROOT/scripts/binate-paths.sh" --iface --base "$ROOT")
IMPL=$("$ROOT/scripts/binate-paths.sh" --impl --base "$ROOT")
(cd "$WORK" && "$BNC" -I "$IFACE" -L "$IMPL" --backend "${BINATE_BACKEND:-native}" --target "$TARGET" \
		$BINATE_FLAGS -c --pkg "$PKG" > "$WORK/bnc.log" 2>&1) ||
	{ cat "$WORK/bnc.log"; exit 1; }
OBJ=$(ls "$WORK"/*.o | head -1)
objdump -d --no-show-raw-insn "$OBJ" > "$WORK/dis.txt"
for fn in "$@"; do
	awk -v want="_${#fn}_${fn}" '
		function hexval(s,   i, c, v) { v = 0; s = tolower(s); sub(/^0x/, "", s)
			for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c }
			return v }
		/^[0-9a-f]+ <.*>:$/ {
			name = $2; sub(/^</, "", name); sub(/>:$/, "", name)
			infn = (length(name) >= length(want) && substr(name, length(name) - length(want) + 1) == want)
			frame = 0; done = 0; next }
		infn && !done {
			if (match($0, /sub[ \t]+sp, sp, #(0x[0-9a-f]+|[0-9]+)/) || match($0, /subq?[ \t]+(\$0x[0-9a-f]+, %rsp|rsp, (0x[0-9a-f]+|[0-9]+))/)) {
				s = substr($0, RSTART, RLENGTH); n = s
				sub(/.*#/, "", n); sub(/.*\$/, "", n); sub(/, %rsp$/, "", n); sub(/.*rsp, /, "", n)
				v = (n ~ /^0x/) ? hexval(n) : n + 0
				if ($0 ~ /lsl #12/) v = v * 4096
				frame += v
				next
			}
			if (frame > 0) { printf "%s %d\n", name, frame; done = 1 }
		}' "$WORK/dis.txt" | sed "s/^.*_${#fn}_${fn} / ${fn} /" | head -1 | awk -v f="$fn" -v t="$TARGET" '{ printf "%-20s %-14s %8d\n", f, t, $2 }'
done
