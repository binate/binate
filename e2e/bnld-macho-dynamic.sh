#!/bin/sh
# e2e/bnld-macho-dynamic.sh — End-to-end proof that the Binate-native linker (bnld)
# produces a RUNNABLE, DYNAMICALLY-linked, ad-hoc-code-signed arm64 Mach-O executable
# for macOS, with no clang/ld in the link.  Programs are assembled with bnas
# (-target macos-arm64) and linked with `bnld -target macos-arm64 -dynamic`: undefined
# externals (_exit, _write) become dynamic imports from libSystem, bound at load by
# /usr/lib/dyld through a synthesized __TEXT stub + __DATA_CONST __got slot.
#   * exit42 — `mov w0,#42 ; bl _exit` → libSystem exit(42); the exit code proves the
#     function-import (stub + __got bind) path end to end.
#   * hello  — write(1, msg, 22) via ADRP+ADD to a .rodata string, then _exit(0): two
#     imports, a data argument, and stdio — plus the rodata path (a __const section
#     before __text) that exercises section-relative symbol addressing.
#   * datum  — GOT-loads the libSystem DATA symbol ___stdoutp and exits 42 iff non-null:
#     the data-import path (__got slot + POINTER bind, no stub, the load kept pointing
#     at the slot) plus a called import — the mixed function+data case.
#   * wdata  — mutates a .data global and a .bss global at runtime and exits with their
#     sum (42): the writable __DATA segment (program .data/.bss sharing it with the
#     __got, whose slot sits after the program .data, so a non-zero bind offset).
#
# Static Mach-O does not run on macOS arm64 (the kernel mandates dyld), so this is the
# path to a bnld-linked binary that runs on this platform.  The build + link +
# structure check run everywhere (host-independent Mach-O byte generation + bnld's own
# ad-hoc CodeDirectory signature).  The RUN needs macOS arm64 + dyld, so it runs
# NATIVELY on the macos-latest CI lane (no Docker — a Mach-O cannot run in a Linux
# container); on any non-macOS host it SKIPs after the build+structure check.
#
# Exit 0 on pass (including run-skipped); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_macho.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ----- build bnas + bnld from the current tree -----
BNAS="$TMP/bnas"
if ! "$BINATE_DIR/scripts/build-bnas.sh" -o "$BNAS" > "$TMP/build_bnas.log" 2>&1; then
    echo "FAIL: could not build bnas" >&2
    cat "$TMP/build_bnas.log" >&2
    exit 1
fi
BNLD="$TMP/bnld"
if ! "$BINATE_DIR/scripts/build-bnld.sh" -o "$BNLD" > "$TMP/build_bnld.log" 2>&1; then
    echo "FAIL: could not build bnld" >&2
    cat "$TMP/build_bnld.log" >&2
    exit 1
fi

# ----- helper: assemble + dynamically link + structure-check a Mach-O program -----
# asm_link_macho <name>: read a .s from stdin, assemble with `bnas -target macos-arm64`
# and link with `bnld -target macos-arm64 -dynamic` to $TMP/<name>, then check the
# output is a 64-bit Mach-O naming the dynamic linker + libSystem.
asm_link_macho() {
    _name="$1"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -target macos-arm64 -o "$TMP/$_name.o" "$TMP/$_name.s" \
            > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -target macos-arm64 -dynamic -e _start -o "$TMP/$_name" "$TMP/$_name.o" \
            > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld could not dynamically link $_name" >&2
        cat "$TMP/$_name.link.log" >&2
        exit 1
    fi
    chmod +x "$TMP/$_name"
    _magic="$(od -An -tx1 -N4 "$TMP/$_name" | tr -d ' \n')"
    if [ "$_magic" != "cffaedfe" ]; then
        echo "FAIL: $_name is not a 64-bit Mach-O (magic $_magic)" >&2
        exit 1
    fi
    if ! grep -q "/usr/lib/dyld" "$TMP/$_name"; then
        echo "FAIL: $_name has no LC_LOAD_DYLINKER (/usr/lib/dyld)" >&2
        exit 1
    fi
    if ! grep -q "libSystem.B.dylib" "$TMP/$_name"; then
        echo "FAIL: $_name does not name libSystem (LC_LOAD_DYLIB)" >&2
        exit 1
    fi
}

# ----- exit42: `mov w0,#42 ; bl _exit` — one libSystem import (_exit). -----
asm_link_macho exit42 <<'EOF'
.arch aarch64
.section text
.global _start
.global _exit
_start:
	mov w0, #42
	bl _exit
EOF
echo "PASS: exit42 links to a dynamically-linked arm64 Mach-O (dyld + libSystem)"

# ----- hello: write(1, msg, 22) via ADRP+ADD to a rodata string, then _exit(0) — TWO
#       imports (_write + _exit), a data argument, stdio, and the rodata/section
#       addressing path. -----
asm_link_macho hello <<'EOF'
.arch aarch64
.section rodata
msg:
	.asciz "hello from bnld macho\n"
.section text
.global _start
.global _write
.global _exit
_start:
	mov x0, #1
	adrp x1, msg
	add x1, x1, #:lo12:msg
	mov x2, #22
	bl _write
	mov w0, #0
	bl _exit
EOF
echo "PASS: hello links to a dynamically-linked arm64 Mach-O (imports _write + _exit)"

# ----- datum: GOT-load the libSystem DATA symbol ___stdoutp (a FILE*) and exit 42 iff
#       non-null — the data-import path (a __got slot + POINTER bind, no stub, the load
#       kept pointing at the slot), plus _exit (a called import), so also the mixed
#       function+data case.  ___stdoutp is a libSystem datum dyld binds at load. -----
asm_link_macho datum <<'EOF'
.arch aarch64
.section text
.global _start
.global ___stdoutp
.global _exit
_start:
	adrp x0, :got:___stdoutp
	ldr x0, [x0, #:got_lo12:___stdoutp]
	ldr x0, [x0]
	cbz x0, Lzero
	mov w0, #42
	bl _exit
Lzero:
	mov w0, #0
	bl _exit
EOF
echo "PASS: datum links to a dynamically-linked arm64 Mach-O (GOT data import: ___stdoutp)"

# ----- wdata: writable program data.  A .data global (40) and a .bss global (0) are
#       mutated at runtime and summed to 42, then _exit(42).  This exercises the
#       writable __DATA segment: program .data/.bss share it with the __got, and _exit
#       is a called import whose __got slot sits AFTER the program .data (so the bind
#       offset is non-zero — the segment-relative __got offset).  A read-only-data
#       binary would fault on the stores; exit 42 proves .data + .bss are writable. -----
asm_link_macho wdata <<'EOF'
.arch aarch64
.section data
dval:
	.uint32 40
.section bss
bval:
	.zero 4
.section text
.global _start
.global _exit
_start:
	adrp x0, dval
	add x0, x0, #:lo12:dval
	ldr w1, [x0]
	add w1, w1, #1
	str w1, [x0]
	ldr w1, [x0]
	adrp x2, bval
	add x2, x2, #:lo12:bval
	ldr w3, [x2]
	add w3, w3, #1
	str w3, [x2]
	ldr w3, [x2]
	add w0, w1, w3
	bl _exit
EOF
echo "PASS: wdata links to a dynamically-linked arm64 Mach-O (writable __DATA: .data + .bss)"

# ----- run: natively on macOS arm64 (the macos-latest CI lane); SKIP elsewhere. -----
# A Mach-O cannot run in a Linux container, so there is no Docker path: the run is
# native-or-skip.
CAN_RUN=0
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then CAN_RUN=1; fi
_skip_note="needs a macOS arm64 host"

if [ "$CAN_RUN" = 1 ]; then
    "$TMP/exit42"; _code=$?
    if [ "$_code" != 42 ]; then
        echo "FAIL: exit42 expected exit 42, got $_code" >&2
        exit 1
    fi
    echo "PASS: exit42 ran — libSystem exit(42) exited 42"

    _out="$("$TMP/hello")"; _code=$?
    if [ "$_code" != 0 ]; then
        echo "FAIL: hello expected exit 0, got $_code" >&2
        exit 1
    fi
    if [ "$_out" != "hello from bnld macho" ]; then
        echo "FAIL: hello expected output 'hello from bnld macho', got '$_out'" >&2
        exit 1
    fi
    echo "PASS: hello ran — printed via libSystem write and exited 0"

    "$TMP/datum"; _code=$?
    if [ "$_code" != 42 ]; then
        echo "FAIL: datum expected exit 42 (libSystem ___stdoutp bound non-null via the GOT), got $_code" >&2
        exit 1
    fi
    echo "PASS: datum ran — GOT-loaded libSystem ___stdoutp (bound by dyld) and exited 42"

    "$TMP/wdata"; _code=$?
    if [ "$_code" != 42 ]; then
        echo "FAIL: wdata expected exit 42 (.data + .bss writable in __DATA), got $_code" >&2
        exit 1
    fi
    echo "PASS: wdata ran — mutated a .data and a .bss global in __DATA and exited 42"
else
    echo "SKIP: Mach-O binaries not run here ($_skip_note) — build+structure verified"
fi

echo "ALL PASS: bnld dynamic Mach-O linking (arm64)"
