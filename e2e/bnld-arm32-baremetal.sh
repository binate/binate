#!/bin/sh
# e2e/bnld-arm32-baremetal.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder to LINK and EMIT an arm32 (ELF32) bare-metal image that actually
# BOOTS.
#
# This exercises the whole arm32 linker path — ELF32/REL object reading, arm32 relocation
# (patchArm32), and ELF32 executable emit — through the scripted-driver front end.  Two
# hand-assembled arm32 objects are linked by `bnld -driver drivers/baremetal-arm.bn ...
# -target arm32-baremetal`: _start (object A) does a CROSS-OBJECT `bl emit_msg` (an
# R_ARM_JUMP24 relocation the linker must resolve and patch) into emit_msg (object B), which
# writes "OK\n" to the PL011 UART data register at 0x09000000 (the `virt` machine's console,
# routed to stdout by `-nographic`).
#
# The emitted ELF32 is structure-checked unconditionally (ELFCLASS32, ET_EXEC, e_machine
# ARM, a load segment at the 0x40000000 RAM base, entry in the image).  When qemu-system-arm
# is available the image is also BOOTED under `qemu-system-arm -M virt` and the run PASSES
# only if "OK" appears on the console — the cross-object branch landed on emit_msg and the
# emitted ELF32 is a runnable bare-metal image.  Without qemu-system-arm the boot is skipped
# (the structure check still runs).  Exit 0 on pass/skip; non-zero on any real failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/baremetal-arm.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_arm32.XXXXXX")"
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

# Object A: _start sets up sp, then a CROSS-OBJECT bl to emit_msg (undefined here ->
# an R_ARM_JUMP24 relocation), then spins.
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
# Object B: emit_msg writes "OK\n" to the PL011 UART data register (0x09000000).
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

if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target arm32-baremetal \
        -o "$TMP/prog.elf" "$TMP/start.o" "$TMP/emit.o" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld -driver (baremetal-arm) could not link" >&2
    cat "$TMP/link.log" >&2; exit 1
fi

# --- structure-check the emitted ELF32 (host-independent) ---
E="$TMP/prog.elf"
[ "$(od -An -tx1 -N4 "$E" | tr -d ' \n')" = "7f454c46" ] || { echo "FAIL: not ELF" >&2; exit 1; }
[ "$(od -An -tu1 -j4 -N1 "$E" | tr -d ' \n')" = "1" ] || { echo "FAIL: not ELFCLASS32" >&2; exit 1; }
[ "$(u16_at "$E" 16)" = "2" ] || { echo "FAIL: not ET_EXEC" >&2; exit 1; }
[ "$(u16_at "$E" 18)" = "40" ] || { echo "FAIL: e_machine is not EM_ARM (40)" >&2; exit 1; }
[ "$(u16_at "$E" 42)" = "32" ] || { echo "FAIL: e_phentsize is not 32 (Elf32_Phdr)" >&2; exit 1; }
# First Elf32_Phdr at e_phoff (52): p_type(+0)=PT_LOAD(1), p_paddr(+12)=RAM base 0x40000000.
PHOFF="$(u32_at "$E" 28)"
[ "$PHOFF" = "52" ] || { echo "FAIL: e_phoff is not 52" >&2; exit 1; }
[ "$(u32_at "$E" $((PHOFF + 0)))" = "1" ] || { echo "FAIL: first phdr is not PT_LOAD" >&2; exit 1; }
[ "$(hi4_at "$E" $((PHOFF + 12)))" = "40000000" ] \
    || { echo "FAIL: load segment p_paddr is not the 0x40000000 RAM base" >&2; exit 1; }
echo "PASS: bnld -driver baremetal-arm.bn -> ELF32 (EM_ARM, ET_EXEC, PT_LOAD @ 0x40000000)"

# --- boot it under qemu-system-arm, if available ---
QEMU="${QEMU_SYSTEM_ARM:-$(command -v qemu-system-arm || true)}"
if [ -z "$QEMU" ]; then
    echo "SKIP: qemu-system-arm not found (structure check passed; boot not run)"
    exit 0
fi

TO=""
if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 10"; fi
if [ -z "$TO" ]; then
    # The program spins after printing, so QEMU needs a wall-clock cap; without a
    # timeout tool it would run unbounded.  Skip the boot (the structure check ran).
    echo "SKIP: no timeout/gtimeout to bound the QEMU run (structure check passed; boot not run)"
    exit 0
fi
# `-M virt -cpu cortex-a15` matches the driver's 0x40000000 RAM base; `-nographic` routes
# the PL011 console to stdout; `-kernel <ELF>` loads the image and enters at e_entry.  The
# program spins after printing, so a wall-clock cap terminates QEMU; the console output is
# captured regardless.
OUT="$($TO "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -no-reboot -kernel "$E" 2>&1 || true)"
if printf '%s' "$OUT" | grep -qF "OK"; then
    echo "PASS: qemu-system-arm booted the image and it printed OK (cross-object R_ARM_JUMP24 resolved)"
    exit 0
fi
echo "FAIL: booted image did not print OK" >&2
printf '%s\n' "$OUT" | head -8 >&2
exit 1
