#!/bin/sh
# Measure stack frames: compile a package with a given bnc and print the stack each
# named function's prologue takes, for one target.
#
# Usage: perf/frame-sizes.sh <bnc> <target> <pkg> <func>...
#   target: host | x86_64-darwin | arm32-linux | ... (a bnc --target key)
#   e.g. perf/frame-sizes.sh /tmp/bnc host pkg/binate/parser parseType parseStructType
# The package is read from the tree the script is in, or from $BINATE_ROOT.  The
# backend is native unless $BINATE_BACKEND names another (llvm), and $BINATE_FLAGS adds
# bnc flags (-O2).
#
# A function is matched by the end of its mangled symbol, `<len>_<name>` (Binate's
# mangling ends a name with its length and the name; a method's symbol does not end
# that way, so methods cannot be named), skipping LLVM's `__shim.` / `__shimP.` wrappers.
# The stack its prologue takes is printed, then in parentheses its two parts: the
# stack adjustments (`sub sp, sp, #N` on aarch64 and arm32, aarch64's `#N, lsl #12`
# being N * 4096; `sub $N, %rsp` on x86-64; or a subtraction of a register loaded with
# the size just before) and the pushes (aarch64's `stp` / `str` to `[sp, #-N]!`;
# x86-64's `push`, 8 bytes each; arm32's `push {...}` and `vpush {...}`, 4 bytes a
# general register, 4 an s and 8 a d register).  The prologue is the run of those
# from the first of them to the next branch, call or return -- LLVM may test or return
# before it.  The two backends keep callee-saved registers differently -- native
# inside the frame it adjusts, LLVM in pushes -- so compare the totals.  An adjustment
# by a register whose value the script cannot follow is marked `?`.  Needs llvm-objdump
# (macOS's objdump): GNU objdump spaces x86-64 operands differently.
set -e
[ $# -ge 4 ] || { sed -n '2,25p' "$0"; exit 2; }
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
objdump -d --no-show-raw-insn --show-all-symbols "$OBJ" > "$WORK/dis.txt"
for fn in "$@"; do
	awk -F '\t' -v want="_${#fn}_${fn}" '
		function num(s,   i, c, v, neg) {
			s = tolower(s); sub(/^[#$]/, "", s); neg = (s ~ /^-/); sub(/^-/, "", s)
			if (s ~ /^0x/) {
				v = 0; s = substr(s, 3)
				for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c }
			} else v = s + 0
			return neg ? -v : v }
		function regbytes(list,   parts, i, k, n, a, b, w) {
			n = 0; k = split(list, parts, /, */)
			for (i = 1; i <= k; i++) {
				if (parts[i] == "") continue
				w = (parts[i] ~ /^d/) ? 8 : (parts[i] ~ /^q/) ? 16 : 4
				if (match(parts[i], /[0-9]+-[a-z]*[0-9]+/)) {
					a = parts[i]; sub(/-.*/, "", a); gsub(/[^0-9]/, "", a)
					b = parts[i]; sub(/.*-/, "", b); gsub(/[^0-9]/, "", b)
					n += (b - a + 1) * w
				} else n += w
			}
			return n }
		function report() {
			if (!infn || reported) return
			printf "%d %d %d\n", frame + pushed, frame, unknown; reported = 1 }
		function isstop(op, args) {
			if (op ~ /^(b|bl|blr|br|blx|bx|ret|retq|call|callq|jmp|jmpq|cbz|cbnz|tbz|tbnz)$/) return 1
			if (op ~ /^b\./ || op ~ /^j[a-z]+$/) return 1
			if (op ~ /^(b|bl|blx|bx)(eq|ne|cs|hs|cc|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le)$/) return 1
			if (op ~ /^pop/ && args ~ /pc/) return 1
			if (op ~ /^ldm/ && args ~ /pc/) return 1
			if (op ~ /^(ldr|mov)/ && args ~ /^pc,/) return 1
			return 0 }
		/^[0-9a-f]+ <.*>:$/ {
			report()
			name = $0; sub(/^[0-9a-f]+ </, "", name); sub(/>:$/, "", name)
			infn = !done && name !~ /__shim/ && length(name) >= length(want) &&
					substr(name, length(name) - length(want) + 1) == want
			frame = 0; pushed = 0; unknown = 0; started = 0; reported = 0; split("", reg)
			if (infn) done = 1
			next }
		infn && !reported {
			op = $2; args = $3; sub(/[ \t]+(##|@|\/\/).*/, "", args)
			if (isstop(op, args)) { if (started) report(); next }
			# Loads of a size into a register, for a later subtraction of it.
			if (op == "movw" || op == "mov" && args ~ /^[rwx][0-9]+, #/) {
				r = args; sub(/,.*/, "", r); v = args; sub(/^[^,]*, /, "", v); reg[r] = num(v); next
			}
			if (op == "movt" && (args ~ /^r[0-9]+, #/ || args ~ /^ip, #/)) {
				r = args; sub(/,.*/, "", r); v = args; sub(/^[^,]*, /, "", v); reg[r] = reg[r] % 65536 + num(v) * 65536; next
			}
			if (op == "movk") {
				r = args; sub(/,.*/, "", r); v = args; sub(/^[^,]*, /, "", v); sh = 0
				if (v ~ /lsl #/) { sh = v; sub(/.*lsl #/, "", sh); sh = num(sh); sub(/,.*/, "", v) }
				reg[r] += num(v) * 2 ^ sh; next
			}
			if (op ~ /^mov(abs)?q?$/ && args ~ /^\$/) {
				v = args; sub(/,.*/, "", v); r = args; sub(/.*, /, "", r); reg[r] = num(v); next
			}
			if (op ~ /^sub/ && args ~ /^sp, sp, #/) {
				v = args; sub(/^sp, sp, #/, "", v); sub(/,.*/, "", v); v = num(v)
				if (args ~ /lsl #12/) v = v * 4096
				frame += v; started = 1; next
			}
			if (op ~ /^sub/ && args ~ /^sp, sp, [a-z]/) {
				r = args; sub(/^sp, sp, /, "", r); sub(/,.*/, "", r); started = 1
				if (r in reg) frame += reg[r]; else if (r == "ip" && ("r12" in reg)) frame += reg["r12"]; else if (r == "r12" && ("ip" in reg)) frame += reg["ip"]; else unknown = 1
				next
			}
			if (op ~ /^sub/ && args ~ /, %rsp$/) {
				v = args; sub(/,.*/, "", v); started = 1
				if (v ~ /^\$/) frame += num(v); else if (v in reg) frame += reg[v]; else unknown = 1
				next
			}
			if ((op == "stp" || op == "str") && match(args, /\[sp, #-[0-9a-fx]+\]!/)) {
				v = substr(args, RSTART, RLENGTH); sub(/.*#-/, "", v); sub(/\]!/, "", v)
				pushed += num(v); started = 1; next
			}
			if (op ~ /^push/ && args ~ /^%/) { pushed += 8; started = 1; next }
			if ((op == "push" || op == "vpush") && args ~ /^\{/) {
				v = args; gsub(/[{}]/, "", v); pushed += regbytes(v); started = 1; next
			}
		}
		END { report(); if (!done) print "-1 0 0" }' "$WORK/dis.txt" | head -1 |
		awk -v f="$fn" -v t="$TARGET" '{
			if ($1 < 0) { printf "%-20s %-14s not found\n", f, t; next }
			printf "%-20s %-14s %8d%s  (%d + %d)\n", f, t, $1, ($3 ? "?" : ""), $2, $1 - $2 }'
done
