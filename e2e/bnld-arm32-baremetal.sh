#!/bin/sh
# e2e/bnld-arm32-baremetal.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder to LINK and EMIT an arm32 (ELF32) bare-metal image that actually
# BOOTS.
#
# This exercises the whole arm32 linker path — ELF32/REL object reading, arm32 relocation
# (patchArm32), and ELF32 executable emit — through the scripted-driver front end.  Two
# hand-assembled arm32 objects are linked by `bnld -driver drivers/baremetal-arm.bn ...
# -target arm32-baremetal`: _start (object A) does a CROSS-OBJECT `bl emit_msg` (an
# R_ARM_CALL relocation the linker must resolve and patch) into emit_msg (object B), which
# writes "OK\n" to the PL011 UART data register at 0x09000000 (the `virt` machine's console,
# routed to stdout by `-nographic`).
#
# The emitted ELF32 is structure-checked unconditionally (ELFCLASS32, ET_EXEC, e_machine
# ARM, a load segment at the 0x40000000 RAM base, entry in the image).  When qemu-system-arm
# is available the image is also BOOTED under `qemu-system-arm -M virt` and the run PASSES
# only if "OK" appears on the console — the cross-object branch landed on emit_msg and the
# emitted ELF32 is a runnable bare-metal image.  Without qemu-system-arm the boot is skipped
# (the structure check still runs).
#
# A second image adds a clang-compiled C object whose constructor writes 'C' to the UART: the
# driver places .init_array between __init_array_start and __init_array_end, and that image's
# _start walks them before emit_msg, so the console must show "COK".  It is linked whenever
# clang is available (clang's arm32 .init_array entry is an R_ARM_TARGET1) and booted when
# qemu-system-arm is.  Exit 0 on pass/skip; non-zero on any real failure.
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
# an R_ARM_CALL relocation), then spins.
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

# --- the C constructor image (see the header): linked whenever clang is available ---
HAVE_CTOR=0
if ! command -v clang > /dev/null 2>&1; then
    echo "SKIP: the C constructor image needs clang"
else
HAVE_CTOR=1
cat > "$TMP/ctor.c" <<'EOF'
__attribute__((constructor)) static void ctor(void) { *(volatile unsigned int *)0x09000000 = 'C'; }
EOF
cat > "$TMP/start_ctor.s" <<'EOF'
.arch arm32
.section text
.global _start
.global emit_msg
.global __init_array_start
.global __init_array_end
_start:
	movw sp, #0x0000
	movt sp, #0x4100
	ldr r4, =__init_array_start
	ldr r5, =__init_array_end
ctor_loop:
	cmp r4, r5
	bhs ctor_done
	ldr r3, [r4], #4
	blx r3
	b ctor_loop
ctor_done:
	bl emit_msg
ctor_halt:
	b ctor_halt
EOF
if ! clang -c -O0 -target armv7a-none-eabi -mfloat-abi=soft -ffreestanding -fno-unwind-tables \
        -o "$TMP/ctor.o" "$TMP/ctor.c" > "$TMP/ctor.cc.log" 2>&1; then
    echo "FAIL: clang could not compile ctor.c" >&2; cat "$TMP/ctor.cc.log" >&2; exit 1
fi
if ! "$BNAS" -arch arm32 -o "$TMP/start_ctor.o" "$TMP/start_ctor.s" > "$TMP/start_ctor.asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble start_ctor.s" >&2; cat "$TMP/start_ctor.asm.log" >&2; exit 1
fi
if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target arm32-baremetal \
        -o "$TMP/ctor.elf" "$TMP/start_ctor.o" "$TMP/emit.o" "$TMP/ctor.o" > "$TMP/ctor.link.log" 2>&1; then
    echo "FAIL: bnld -driver (baremetal-arm) could not link the constructor image" >&2
    cat "$TMP/ctor.link.log" >&2; exit 1
fi
echo "PASS: the C constructor image links (.init_array placed between its bracketing symbols)"
fi

# --- the unwind-index image: linked whenever clang is available ---
# exidx.c is built with its unwind tables (`.ARM.exidx`, each entry a PREL31 offset to its function
# and its unwind data).  The driver places the index after the code (PlaceArmExidx); check() then
# looks functions up in [__exidx_start, __exidx_end) as libgcc's __gnu_Unwind_Find_exidx does and
# writes 'X' when the table is sorted, leaf's entry starts at leaf and carries unwind data, big's
# (whose frame's opcodes do not fit an entry) points into `.ARM.extab`, which the driver places
# too, emit_msg (asm, with no index) has an EXIDX_CANTUNWIND entry of its own, and a CANTUNWIND
# sentinel ends the table — else a letter naming the failed check.  So the console must show
# "XOK".  The stub defines the personality routines the entries name (libgcc's otherwise).
if [ "$HAVE_CTOR" = 1 ]; then
cat > "$TMP/exidx.c" <<'EOF'
extern const unsigned int __exidx_start[], __exidx_end[];
extern void emit_msg(void);
static unsigned long fn(const unsigned int *e) { long v = (long)(e[0] << 1) >> 1; return (unsigned long)e + v; }
static const unsigned int *find(unsigned long pc) {
	int l = 0, h = (int)(__exidx_end - __exidx_start) / 2 - 1;
	const unsigned int *best = 0;
	while (l <= h) {
		int m = (l + h) / 2;
		const unsigned int *e = __exidx_start + 2 * m;
		if (fn(e) <= pc) { best = e; l = m + 1; } else { h = m - 1; }
	}
	return best;
}
int leaf(int x) { return x + 1; }
int big(int x) { volatile char buf[5000]; buf[x] = 1; return buf[x]; }
void check(void) {
	char r = 'X';
	int n = (int)(__exidx_end - __exidx_start) / 2;
	for (int i = 0; i + 1 < n; i++) {
		if (fn(__exidx_start + 2 * i) > fn(__exidx_start + 2 * i + 2)) r = 's';
	}
	const unsigned int *e = find((unsigned long)leaf);
	if (!e || fn(e) != (unsigned long)leaf || e[1] == 1) r = 'l';
	e = find((unsigned long)big);
	if (!e || fn(e) != (unsigned long)big || e[1] == 1 || (e[1] & 0x80000000u)) r = 'x';
	else if (*(const unsigned int *)fn(e + 1) == 0) r = 'y';
	e = find((unsigned long)emit_msg);
	if (!e || fn(e) != (unsigned long)emit_msg || e[1] != 1) r = 'm';
	if (n < 1 || __exidx_end[-1] != 1) r = 'z';
	*(volatile unsigned int *)0x09000000 = r;
}
EOF
cat > "$TMP/start_exidx.s" <<'EOF'
.arch arm32
.section text
.global _start
.global check
.global emit_msg
.global __aeabi_unwind_cpp_pr0
.global __aeabi_unwind_cpp_pr1
_start:
	movw sp, #0x0000
	movt sp, #0x4100
	bl check
	bl emit_msg
exidx_halt:
	b exidx_halt
__aeabi_unwind_cpp_pr0:
__aeabi_unwind_cpp_pr1:
	bx lr
EOF
if ! clang -c -O0 -target armv7a-none-eabi -mfloat-abi=soft -ffreestanding -funwind-tables \
        -o "$TMP/exidx.o" "$TMP/exidx.c" > "$TMP/exidx.cc.log" 2>&1; then
    echo "FAIL: clang could not compile exidx.c" >&2; cat "$TMP/exidx.cc.log" >&2; exit 1
fi
if ! "$BNAS" -arch arm32 -o "$TMP/start_exidx.o" "$TMP/start_exidx.s" > "$TMP/start_exidx.asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble start_exidx.s" >&2; cat "$TMP/start_exidx.asm.log" >&2; exit 1
fi
if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target arm32-baremetal \
        -o "$TMP/exidx.elf" "$TMP/start_exidx.o" "$TMP/emit.o" "$TMP/exidx.o" > "$TMP/exidx.link.log" 2>&1; then
    echo "FAIL: bnld -driver (baremetal-arm) could not link the unwind-index image" >&2
    cat "$TMP/exidx.link.log" >&2; exit 1
fi
echo "PASS: the unwind-index image links (.ARM.exidx placed between __exidx_start and __exidx_end)"
fi

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
if ! printf '%s' "$OUT" | grep -qF "OK"; then
    echo "FAIL: booted image did not print OK" >&2
    printf '%s\n' "$OUT" | head -8 >&2
    exit 1
fi
echo "PASS: qemu-system-arm booted the image and it printed OK (cross-object R_ARM_CALL resolved)"

[ "$HAVE_CTOR" = 1 ] || exit 0
OUT="$($TO "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -no-reboot -kernel "$TMP/ctor.elf" 2>&1 || true)"
if ! printf '%s' "$OUT" | grep -qF "COK"; then
    echo "FAIL: the constructor image did not print COK (the constructor before emit_msg)" >&2
    printf '%s\n' "$OUT" | head -8 >&2
    exit 1
fi
echo "PASS: the C constructor ran from .init_array before emit_msg (printed COK)"
OUT="$($TO "$QEMU" -M virt -cpu cortex-a15 -m 16M -nographic -no-reboot -kernel "$TMP/exidx.elf" 2>&1 || true)"
if ! printf '%s' "$OUT" | grep -qF "XOK"; then
    echo "FAIL: the unwind-index image did not print XOK (its table lookup failed)" >&2
    printf '%s\n' "$OUT" | head -8 >&2
    exit 1
fi
echo "PASS: the unwind index is sorted and covers the C and asm code (printed XOK)"
exit 0
