#!/bin/sh
# e2e/bnld-arm32-firmware.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder's full linker-script feature set — multiple MEMORY regions, a
# ROM→RAM data copy (LMA≠VMA), and boundary/region symbols — to emit an arm32 (ELF32)
# firmware image (the case-A shape).
#
# `bnld -driver drivers/firmware-arm.bn <objs> -o out -target arm32-firmware` runs the
# driver: it declares FLASH + RAM regions, places .text/.rodata in FLASH, and places .data
# with its VMA in RAM but its LMA in FLASH (`AT> FLASH`) so the image ships in flash and a
# startup would copy it to RAM.  This exercises DefineRegion / SetDotToRegion /
# SectionAtRegion / SectionLoadRegion / SymbolAtDot / DefineSymbol / LoadAddrOf as METHODS
# on the opaque link.LayoutBuilder.
#
# The image is STRUCTURE-checked, not booted: a real Cortex-M firmware runs in Thumb (which
# bnas does not emit) and its startup would consume the boundary symbols (which a hand-asm
# program cannot reference), so this proves the LAYOUT — the ROM-copy segment whose p_vaddr
# (RAM) differs from its p_paddr (FLASH) — the observable capability the API adds.  The
# symbol VALUES are covered by the builder unit tests.  Exit 0 on pass; non-zero on failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/firmware-arm.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_fw.XXXXXX")"
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

w32_at() { od -An -tx4 -j"$2" -N4 "$1" | tr -d ' \n'; }  # the 4-byte LE word at <off> as hex
u16_at() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }

# A firmware object: _start in .text (FLASH) plus a .data word (RAM at run, FLASH image),
# so both the FLASH code segment and the ROM-copy .data segment are populated.
cat > "$TMP/fw.s" <<'EOF'
.arch arm32
.section text
.global _start
_start:
	bx lr
.section data
dval:
	.int32 0x12345678
EOF
if ! "$BNAS" -arch arm32 -o "$TMP/fw.o" "$TMP/fw.s" > "$TMP/fw.asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble the firmware stub" >&2; cat "$TMP/fw.asm.log" >&2; exit 1
fi
if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target arm32-firmware \
        -o "$TMP/fw.elf" "$TMP/fw.o" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld -driver (firmware-arm) could not link" >&2
    cat "$TMP/link.log" >&2; exit 1
fi

E="$TMP/fw.elf"
[ "$(od -An -tx1 -N4 "$E" | tr -d ' \n')" = "7f454c46" ] || { echo "FAIL: not ELF" >&2; exit 1; }
[ "$(od -An -tu1 -j4 -N1 "$E" | tr -d ' \n')" = "1" ] || { echo "FAIL: not ELFCLASS32" >&2; exit 1; }
[ "$(u16_at "$E" 16)" = "2" ] || { echo "FAIL: not ET_EXEC" >&2; exit 1; }
[ "$(u16_at "$E" 18)" = "40" ] || { echo "FAIL: e_machine is not EM_ARM (40)" >&2; exit 1; }
[ "$(u16_at "$E" 44)" = "2" ] || { echo "FAIL: expected two PT_LOADs (FLASH code + ROM-copy data)" >&2; exit 1; }

# Elf32_Phdr is 32 bytes at e_phoff (52): p_type(+0), p_vaddr(+8), p_paddr(+12), p_flags(+24).
# Segments are sorted by load address, so phdr[0] is the FLASH code segment (VMA==LMA in
# FLASH) and phdr[1] is the .data ROM-copy segment (VMA in RAM, LMA in FLASH).
ph0=52
ph1=$((52 + 32))
[ "$(w32_at "$E" $((ph0 + 8)))" = "08000000" ] || { echo "FAIL: code segment VMA not in FLASH" >&2; exit 1; }
[ "$(w32_at "$E" $((ph0 + 12)))" = "08000000" ] || { echo "FAIL: code segment LMA not in FLASH" >&2; exit 1; }
[ "$(w32_at "$E" $((ph0 + 24)))" = "00000005" ] || { echo "FAIL: code segment not R+X" >&2; exit 1; }

VD="$(w32_at "$E" $((ph1 + 8)))"   # .data p_vaddr (run address)
PD="$(w32_at "$E" $((ph1 + 12)))"  # .data p_paddr (load address)
[ "$VD" = "20000000" ] || { echo "FAIL: .data run address (p_vaddr) not the RAM base 0x20000000" >&2; exit 1; }
[ "${PD#08}" != "$PD" ] || { echo "FAIL: .data load address (p_paddr) not in FLASH (0x08xxxxxx)" >&2; exit 1; }
[ "$VD" != "$PD" ] || { echo "FAIL: .data LMA must differ from its VMA (ROM-copy)" >&2; exit 1; }
[ "$(w32_at "$E" $((ph1 + 24)))" = "00000006" ] || { echo "FAIL: .data segment not R+W" >&2; exit 1; }

echo "PASS: bnld -driver firmware-arm.bn → ELF32 firmware (FLASH code + .data ROM-copy, VMA=$VD LMA=$PD)"
exit 0
