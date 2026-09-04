#!/bin/sh
# e2e/bnld-higherhalf.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder to emit a higher-half kernel ELF with EXPLICIT program headers and
# LMA≠VMA.
#
# `bnld -driver drivers/higherhalf.bn <objs> -o out -target linux-x64` runs the driver:
# it declares two explicit segments (DefineSegment text R+X, data R+W), places .text/.rodata
# and .data/.bss so they RUN in the high half (0xffffffff80000000 + physical) but LOAD at
# their physical address (SectionLoadAddr = AT(Dot() - KVMA)), and calls EmitElf — which
# takes the explicit-PHDRS path (EmitElfExecPhdrs).  This exercises the scripted engine's
# explicit-segment + LMA≠VMA emit as METHODS on the opaque link.LayoutBuilder.
#
# A higher-half kernel is placed low by a multiboot loader and runs high once paging is on;
# it is not a hosted executable, so this STRUCTURE-CHECKS the emitted image (running it needs
# a bootloader + QEMU, out of scope here).  The checks: ET_EXEC, a high-half entry, two
# PT_LOADs each with p_vaddr in the high half and p_paddr at the physical load address, the
# first R+X and the second R+W.  Exit 0 on pass; non-zero on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/higherhalf.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_higherhalf.XXXXXX")"
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

hi4_at() { od -An -tx4 -j"$2" -N4 "$1" | tr -d ' \n'; }  # the 4 bytes at <off> as hex
u16_at() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }
u32_at() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }

# A minimal kernel object: _start in .text plus a .data word, so both explicit segments
# (text R+X, data R+W) are populated.
cat > "$TMP/kern.s" <<'EOF'
.arch x64
.section data
val:
	.int32 42
.section text
.global _start
_start:
	mov eax, 60
	mov edi, 42
	syscall
EOF
if ! "$BNAS" -target linux-x64 -o "$TMP/kern.o" "$TMP/kern.s" > "$TMP/kern.asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble the kernel stub" >&2; cat "$TMP/kern.asm.log" >&2; exit 1
fi
if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target linux-x64 \
        -o "$TMP/kern" "$TMP/kern.o" > "$TMP/kern.link.log" 2>&1; then
    echo "FAIL: bnld -driver (higherhalf) could not link the kernel" >&2
    cat "$TMP/kern.link.log" >&2; exit 1
fi

K="$TMP/kern"
[ "$(od -An -tx1 -N4 "$K" | tr -d ' \n')" = "7f454c46" ] || { echo "FAIL: not ELF" >&2; exit 1; }
[ "$(u16_at "$K" 16)" = "2" ] || { echo "FAIL: not ET_EXEC" >&2; exit 1; }
# High-half entry: the upper 4 bytes of e_entry (offset 24, 8 bytes) are 0xffffffff.
[ "$(hi4_at "$K" 28)" = "ffffffff" ] || { echo "FAIL: entry is not in the high half" >&2; exit 1; }
[ "$(u16_at "$K" 56)" = "2" ] || { echo "FAIL: expected two explicit PT_LOADs" >&2; exit 1; }

# Each segment: p_vaddr (phdr+16) high half, p_paddr (phdr+24) physical (upper word 0).
check_seg() {
    _ph="$1"; _name="$2"; _wflags="$3"
    [ "$(hi4_at "$K" $((_ph + 20)))" = "ffffffff" ] \
        || { echo "FAIL: $_name p_vaddr not high-half" >&2; exit 1; }
    [ "$(hi4_at "$K" $((_ph + 28)))" = "00000000" ] \
        || { echo "FAIL: $_name p_paddr not physical (upper word nonzero)" >&2; exit 1; }
    [ "$(u32_at "$K" $((_ph + 4)))" = "$_wflags" ] \
        || { echo "FAIL: $_name flags $(u32_at "$K" $((_ph + 4))), want $_wflags" >&2; exit 1; }
}
check_seg 64 "text segment" 5   # PF_R|PF_X
check_seg 120 "data segment" 6  # PF_R|PF_W

echo "PASS: bnld -driver higherhalf.bn → higher-half ELF (2 explicit PT_LOADs, vaddr high / paddr physical, W^X)"
exit 0
