#!/bin/sh
# e2e/bnld-arm32-script.sh — End-to-end proof that a bnld driver using the DECLARATIVE
# Layer-2 spec (link.LayoutScript + link.LinkWithScript) produces a bootable arm32 (ELF32)
# image — the sugar layer driving the same read/relocate/emit path as the imperative one.
#
# `bnld -driver drivers/script-arm.bn <objs> -o out -target arm32-script` runs the driver:
# it builds a LayoutScript (start dot at the RAM base, ordered sections with `*(GLOB)`
# placements + boundary symbols, an entry) and calls LinkWithScript.  Two hand-assembled
# arm32 objects are linked: _start (object A) does a CROSS-OBJECT `bl emit_msg` (an
# R_ARM_JUMP24 the linker resolves + patches) into emit_msg (object B), which writes "OK\n"
# to the PL011 UART at 0x09000000 (routed to stdout by `-nographic`).
#
# The emitted ELF32 is structure-checked, then — when qemu-system-arm is available — BOOTED
# under `-M virt`; it PASSES only if "OK" appears (the cross-object branch landed and the
# declaratively-built image runs).  Without qemu-system-arm / a timeout tool the boot is
# skipped (the structure check still runs).  Exit 0 on pass/skip; non-zero on a real failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/script-arm.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_a32script.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BNAS="$TMP/bnas"
if ! "$BINATE_DIR/scripts/build-bnas.sh" -o "$BNAS" > "$TMP/build_bnas.log" 2>&1; then
    echo "FAIL: could not build bnas" >&2; cat "$TMP/build_bnas.log" >&2; exit 1
fi
BNLD="$TMP/bnld"
if ! "$BINATE_DIR/scripts/build-bnld.sh" -o "$BNLD" > "$TMP/build_bnld.log" 2>&1; then
    echo "FAIL: could not build bnld" >&2; cat "$TMP/build_bnld.log" >&2; exit 1
fi

IFACE_DIRS="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL_DIRS="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"

u16_at() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }
w32_at() { od -An -tx4 -j"$2" -N4 "$1" | tr -d ' \n'; }

cat > "$TMP/start.s" <<'EOF'
.arch arm32
.section text
.global _start
.global emit_msg
_start:
	movw sp, #0x0000
	movt sp, #0x4100
	bl emit_msg
start_halt:
	b start_halt
EOF
cat > "$TMP/emit.s" <<'EOF'
.arch arm32
.section text
.global emit_msg
emit_msg:
	movw r0, #0x0000
	movt r0, #0x0900
	mov r1, #0x4f
	str r1, [r0]
	mov r1, #0x4b
	str r1, [r0]
	mov r1, #0x0a
	str r1, [r0]
	bx lr
EOF
for f in start emit; do
    if ! "$BNAS" -arch arm32 -o "$TMP/$f.o" "$TMP/$f.s" > "$TMP/$f.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $f.s" >&2; cat "$TMP/$f.asm.log" >&2; exit 1
    fi
done

if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target arm32-script \
        -o "$TMP/prog.elf" "$TMP/start.o" "$TMP/emit.o" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld -driver (script-arm) could not link" >&2
    cat "$TMP/link.log" >&2; exit 1
fi

E="$TMP/prog.elf"
[ "$(od -An -tx1 -N4 "$E" | tr -d ' \n')" = "7f454c46" ] || { echo "FAIL: not ELF" >&2; exit 1; }
[ "$(od -An -tu1 -j4 -N1 "$E" | tr -d ' \n')" = "1" ] || { echo "FAIL: not ELFCLASS32" >&2; exit 1; }
[ "$(u16_at "$E" 16)" = "2" ] || { echo "FAIL: not ET_EXEC" >&2; exit 1; }
[ "$(u16_at "$E" 18)" = "40" ] || { echo "FAIL: e_machine is not EM_ARM (40)" >&2; exit 1; }
[ "$(w32_at "$E" $((52 + 12)))" = "40000000" ] \
    || { echo "FAIL: first PT_LOAD p_paddr is not the 0x40000000 RAM base" >&2; exit 1; }
echo "PASS: bnld -driver script-arm.bn (Layer-2) → ELF32 (EM_ARM, PT_LOAD @ 0x40000000)"

QEMU="${QEMU_SYSTEM_ARM:-$(command -v qemu-system-arm || true)}"
if [ -z "$QEMU" ]; then
    echo "SKIP: qemu-system-arm not found (structure check passed; boot not run)"
    exit 0
fi
TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 10"; fi
if [ -z "$TO" ]; then
    echo "SKIP: no timeout/gtimeout to bound the QEMU run (structure check passed; boot not run)"
    exit 0
fi
OUT="$($TO "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -no-reboot -kernel "$E" 2>&1 || true)"
if printf '%s' "$OUT" | grep -qF "OK"; then
    echo "PASS: qemu-system-arm booted the declaratively-linked image and it printed OK"
    exit 0
fi
echo "FAIL: booted image did not print OK" >&2
printf '%s\n' "$OUT" | head -8 >&2
exit 1
