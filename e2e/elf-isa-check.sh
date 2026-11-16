#!/bin/sh
# e2e/elf-isa-check.sh — scripts/check-elf-isa.sh accepts an x86-64 ELF object that
# needs at most the x86-64 baseline and rejects one that needs x86-64-v3.
#
# Each object is assembled by clang from a .note.gnu.property carrying
# GNU_PROPERTY_X86_ISA_1_NEEDED (0xc0008002) with the given level bits (baseline 1,
# v2 2, v3 4), or no note at all; readelf reports such a note as "x86 ISA needed:".
set -eu

BINATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$BINATE_DIR/scripts/check-elf-isa.sh"

if ! command -v readelf >/dev/null 2>&1 && ! command -v llvm-readelf >/dev/null 2>&1; then
    echo "SKIP: no readelf or llvm-readelf to read ELF notes with"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_elf_isa.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# note_obj <name> <level bits>: an object whose only content is the ISA-needed note.
note_obj() {
    cat > "$TMP/$1.s" <<EOF
.section .note.gnu.property,"a"
.p2align 3
.long 4
.long 16
.long 5
.asciz "GNU"
.long 0xc0008002
.long 4
.long $2
.p2align 3
EOF
    clang --target=x86_64-linux-gnu -c "$TMP/$1.s" -o "$TMP/$1.o"
}
note_obj baseline 1
note_obj v3 7
printf '.text\nnop\n' > "$TMP/plain.s"
clang --target=x86_64-linux-gnu -c "$TMP/plain.s" -o "$TMP/plain.o"

if ! "$CHECK" "$TMP/baseline.o" "$TMP/plain.o"; then
    echo "FAIL: an object needing only the baseline (or nothing) was rejected" >&2
    exit 1
fi
if "$CHECK" "$TMP/v3.o" > "$TMP/v3.log" 2>&1; then
    echo "FAIL: an object needing x86-64-v3 was accepted" >&2
    exit 1
fi
if ! grep -q "x86-64-v3" "$TMP/v3.log"; then
    echo "FAIL: the rejection does not name the level:" >&2
    cat "$TMP/v3.log" >&2
    exit 1
fi

echo "PASS: check-elf-isa.sh accepts the x86-64 baseline and rejects x86-64-v3"
