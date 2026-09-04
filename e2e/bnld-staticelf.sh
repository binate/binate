#!/bin/sh
# e2e/bnld-staticelf.sh — End-to-end proof that an INTERPRETED bnld driver drives the
# scripted LayoutBuilder to emit a RUNNABLE static ELF64 executable.
#
# `bnld -driver drivers/staticelf.bn <objs> -o out -target <t>` embeds the bytecode VM,
# injects the compiled pkg/binate/link library as externs, and runs the driver's Drive
# entry: it places the read-only group (.text then .rodata) at the load base, page-aligns
# the writable group (.data/.bss) onto a fresh page, resolves _start, and calls EmitElf.
# Unlike drivers/elf.bn (which calls the whole-link link.Link), this drives the primitive
# LayoutBuilder + EmitElf — proving the scripted layout path produces a valid, runnable
# static executable, and exercising the shipped builder API methods (SetDot / BeginSection
# / Place / AlignDot / SetEntry / Finish / EmitElf) as METHODS on the opaque
# link.LayoutBuilder across the compiled<->interpreted boundary.
#
# Two hand-asm x86-64 programs are assembled with bnas, linked by the scripted driver,
# structure-checked (static ELF64 ET_EXEC, entry at _start, W^X), and run:
#   * exit42 — exits 42 (only .text; a single R+X PT_LOAD, no empty segments).
#   * hello  — writes "hi\n" then exits 0 (.rodata via a PC-relative reloc).
# An aarch64 exit42 is also linked (-target linux-aarch64) and structure-checked, proving
# the driver's machine selection.  The run needs a linux-x86-64 runtime (native, or Docker
# on a Mac); where it can't run, the build + structure check still assert a valid image.
# Exit 0 on pass (incl. run-skipped); non-zero on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
DRIVER="$BINATE_DIR/drivers/staticelf.bn"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_staticelf.XXXXXX")"
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

u16_at() { od -An -tu2 -j"$2" -N2 "$1" | tr -d ' \n'; }

# check_elf <path> <name> <want-e_machine>: static ELF64 ET_EXEC, entry at the load base
# (0x400000 — proves SetEntry resolved _start), and the expected e_machine.
check_elf() {
    _p="$1"; _n="$2"; _em="$3"
    if [ "$(od -An -tx1 -N4 "$_p" | tr -d ' \n')" != "7f454c46" ]; then
        echo "FAIL: $_n is not an ELF file" >&2; exit 1
    fi
    if [ "$(u16_at "$_p" 16)" != "2" ]; then echo "FAIL: $_n is not ET_EXEC" >&2; exit 1; fi
    if [ "$(u16_at "$_p" 18)" != "$_em" ]; then
        echo "FAIL: $_n e_machine=$(u16_at "$_p" 18), want $_em" >&2; exit 1
    fi
    # e_entry (8 bytes at offset 24) low 4 bytes == 0x00400000.
    if [ "$(od -An -tx4 -j24 -N4 "$_p" | tr -d ' \n')" != "00400000" ]; then
        echo "FAIL: $_n entry is not the _start load base 0x400000" >&2; exit 1
    fi
    if [ ! -x "$_p" ]; then echo "FAIL: $_n is not owner-executable" >&2; exit 1; fi
}

# drv_link <name> <target> <want-e_machine>: assemble stdin .s, link via the scripted
# driver, structure-check.  bnas uses -target (linux-* selects ELF) so the object is ELF
# for the driver's link.ReadObject — bnas -arch aarch64 alone defaults to Mach-O.
drv_link() {
    _name="$1"; _target="$2"; _em="$3"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -target "$_target" -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2; cat "$TMP/$_name.asm.log" >&2; exit 1
    fi
    if ! "$BNLD" -driver "$DRIVER" -I "$IFACE_DIRS" --impl-path "$IMPL_DIRS" -target "$_target" \
            -o "$TMP/$_name" "$TMP/$_name.o" > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld -driver (staticelf) could not link $_name" >&2
        cat "$TMP/$_name.link.log" >&2; exit 1
    fi
    check_elf "$TMP/$_name" "$_name" "$_em"
    echo "PASS: $_name linked via the scripted-layout driver → static ELF64 (e_machine $_em)"
}

drv_link exit42 linux-x64 62 <<'EOF'
.arch x64
.section text
.global _start
_start:
	mov edi, 42
	mov eax, 60
	syscall
EOF

drv_link hello linux-x64 62 <<'EOF'
.arch x64
.section rodata
msg:
	.ascii "hi\n"
.section text
.global _start
_start:
	mov eax, 1
	mov edi, 1
	lea rsi, [rip + msg]
	mov edx, 3
	syscall
	mov eax, 60
	xor edi, edi
	syscall
EOF

# aarch64: same driver, linux-aarch64 target — proves machine selection + EmitElf for
# aarch64 (e_machine 183).  The RUN of a static aarch64 ELF is covered elsewhere.
drv_link exit42_aa linux-aarch64 183 <<'EOF'
.arch aarch64
.section text
.global _start
_start:
	mov x0, #42
	mov x8, #93
	svc #0
EOF

# ----- run the x86-64 programs if a linux-x86-64 runtime is available -----
CAN_RUN=0
RUN_KIND=""
case "$(uname -s)" in
    Linux) case "$(uname -m)" in x86_64 | amd64) CAN_RUN=1; RUN_KIND=native ;; esac ;;
    Darwin)
        if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1 \
                && docker pull --platform linux/amd64 alpine > /dev/null 2>&1; then
            CAN_RUN=1; RUN_KIND=docker
        fi ;;
esac

run_expect() {
    _name="$1"; _wcode="$2"; _wout="$3"
    if [ "$CAN_RUN" != 1 ]; then
        echo "SKIP: $_name run (no linux-x86-64 runtime) — build+structure verified"
        return
    fi
    _out=""; _code=0
    if [ "$RUN_KIND" = native ]; then
        _out="$("$TMP/$_name")"; _code=$?
    else
        _out="$(docker run --rm --platform linux/amd64 -v "$TMP:/w" alpine "/w/$_name" 2>/dev/null)"
        _code=$?
        case "$_code" in 125 | 127) echo "SKIP: $_name run (docker infra)"; return ;; esac
    fi
    if [ "$_code" != "$_wcode" ]; then echo "FAIL: $_name exited $_code, want $_wcode" >&2; exit 1; fi
    if [ "$_out" != "$_wout" ]; then echo "FAIL: $_name printed '$_out', want '$_wout'" >&2; exit 1; fi
    echo "PASS: $_name ran (scripted-driver-linked) → exit $_code"
}

run_expect exit42 42 ""
run_expect hello 0 "hi"

echo "ALL PASS: bnld -driver staticelf.bn (scripted LayoutBuilder → EmitElf) static ELF"
exit 0
