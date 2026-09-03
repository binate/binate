#!/bin/sh
# e2e/bnld-rawbin.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder to emit a RAW BINARY (no ELF/Mach-O container).
#
# `bnld -driver drivers/rawbin.bn <obj> -o out.bin` embeds the bytecode VM, injects the
# compiled pkg/binate/link library as externs, and runs the driver's Drive entry: it
# reads the object, places its .text at the BIOS boot address 0x7C00, pads to offset 510,
# appends the 0x55AA boot signature, and calls EmitRawBinary — producing a 512-byte MBR
# image.  This exercises the scripted-layout primitives (SetDot/BeginSection/Place/PadTo/
# EmitData/Finish/EmitRawBinary) end to end, and — since those are METHODS on the opaque
# link.LayoutBuilder — the interp's opaque-imported-type registration (without which the
# method calls mis-dispatch to a phantom `int` receiver).
#
# Arch-agnostic and host-independent: it only builds + structure-checks the emitted bytes
# (a boot sector is not an executable to run).  Exit 0 on pass, non-zero on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/rawbin.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_rawbin.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ----- build bnas + bnld from the current tree -----
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

# byte_at <path> <offset>: the hex byte at <offset>, e.g. "55".
byte_at() { od -An -tx1 -j"$2" -N1 "$1" | tr -d ' \n'; }

# ----- assemble a boot stub: a recognizable, relocation-free .text -----
# `mov eax, 0xcafebabe` (b8 be ba fe ca) is a distinctive immediate proving the object's
# own bytes were placed at offset 0; the self `jmp` keeps it a valid stub.
cat > "$TMP/boot.s" <<'EOF'
.arch x64
.section text
_start:
	mov eax, 0xcafebabe
	jmp _start
EOF
if ! "$BNAS" -arch x64 -o "$TMP/boot.o" "$TMP/boot.s" > "$TMP/boot.asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble the boot stub" >&2; cat "$TMP/boot.asm.log" >&2; exit 1
fi

# ----- link via the interpreted rawbin driver -----
if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" \
        -o "$TMP/boot.bin" "$TMP/boot.o" > "$TMP/boot.link.log" 2>&1; then
    echo "FAIL: bnld -driver could not build the raw image" >&2; cat "$TMP/boot.link.log" >&2; exit 1
fi

# ----- structure-check the 512-byte boot image -----
SZ="$(wc -c < "$TMP/boot.bin" | tr -d ' ')"
if [ "$SZ" != "512" ]; then
    echo "FAIL: image is $SZ bytes, want 512" >&2; exit 1
fi
# The object's code (mov eax, 0xcafebabe) is at offset 0 — proves Place read + placed it.
if [ "$(byte_at "$TMP/boot.bin" 0)" != "b8" ] || [ "$(byte_at "$TMP/boot.bin" 1)" != "be" ] \
        || [ "$(byte_at "$TMP/boot.bin" 2)" != "ba" ] || [ "$(byte_at "$TMP/boot.bin" 3)" != "fe" ] \
        || [ "$(byte_at "$TMP/boot.bin" 4)" != "ca" ]; then
    echo "FAIL: boot code (mov eax, 0xcafebabe) not at offset 0" >&2; exit 1
fi
# The gap between the code and the signature is zero-filled (PadTo).
if [ "$(byte_at "$TMP/boot.bin" 256)" != "00" ]; then
    echo "FAIL: the pad gap is not zero-filled" >&2; exit 1
fi
# The 0x55AA boot signature is at offset 510 (PadTo to 510 + EmitData).
if [ "$(byte_at "$TMP/boot.bin" 510)" != "55" ] || [ "$(byte_at "$TMP/boot.bin" 511)" != "aa" ]; then
    echo "FAIL: boot signature 0x55AA not at offset 510" >&2; exit 1
fi

echo "PASS: bnld -driver rawbin.bn → 512-byte MBR image (code at 0, 0x55AA at 510)"
exit 0
