#!/bin/sh
# e2e/bnld-linux.sh — End-to-end proof that the Binate-native linker (bnld)
# produces RUNNABLE static ELF64 x86-64 executables, with no clang/ld in the link.
# Two programs are assembled with bnas, linked with bnld, checked to be static
# ELF64 ET_EXEC, and run:
#   * exit42 — exits 42 (pins the exit-code path; no relocations).
#   * hello  — writes "hi\n" then exits 0 (exercises a .rodata section and a
#              PC-relative relocation from .text into .rodata, at run time).
#
# The run needs a linux-x86-64 environment: native on an x86-64 Linux host, via
# Docker on a Mac host.  Where it can't run (a non-x86-64 host, no Docker, or a
# Docker infrastructure error) the assemble+link+structure check still gates and
# the execution reports SKIP — so a correct linker is never blamed for the
# environment, while a broken one still reddens the Linux lane.
#
# Exit 0 on pass (including run-skipped); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld.XXXXXX")"
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

# check_elf <path> <name>: the linked output must be a static ELF64 ET_EXEC that
# is owner-executable.
check_elf() {
    _p="$1"
    _n="$2"
    _magic="$(od -An -tx1 -N4 "$_p" | tr -d ' \n')"
    if [ "$_magic" != "7f454c46" ]; then
        echo "FAIL: $_n is not an ELF file (magic=$_magic)" >&2
        exit 1
    fi
    _class="$(od -An -tu1 -j4 -N1 "$_p" | tr -d ' \n')"
    if [ "$_class" != "2" ]; then
        echo "FAIL: $_n is not ELF64 (EI_CLASS=$_class)" >&2
        exit 1
    fi
    _etype="$(od -An -tu1 -j16 -N1 "$_p" | tr -d ' \n')"
    if [ "$_etype" != "2" ]; then
        echo "FAIL: $_n is not ET_EXEC (e_type=$_etype)" >&2
        exit 1
    fi
    if [ ! -x "$_p" ]; then
        echo "FAIL: $_n is not owner-executable" >&2
        exit 1
    fi
}

# asm_link <name>: read a .s from stdin, assemble with bnas and link with bnld to
# $TMP/<name>, and structure-check the result.  FAILs the whole test on error.
asm_link() {
    _name="$1"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -arch x64 -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -o "$TMP/$_name" "$TMP/$_name.o" > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld could not link $_name" >&2
        cat "$TMP/$_name.link.log" >&2
        exit 1
    fi
    check_elf "$TMP/$_name" "$_name"
}

# ----- exit42: exits 42 (no relocations) -----
asm_link exit42 <<'EOF'
.arch x64
.section text
.global _start
_start:
	mov edi, 42
	mov eax, 60
	syscall
EOF
echo "PASS: exit(42) links to a static ELF64 x86-64 executable"

# ----- hello: writes "hi\n" then exits 0 (a .rodata string reached by a
#       PC-relative relocation from .text) -----
asm_link hello <<'EOF'
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
echo "PASS: hello links to a static ELF64 x86-64 executable"

# ----- run both programs if a linux-x86-64 runtime is available -----
# Detect the runtime once (and pull the image on the Docker path) so a missing
# runtime / Docker daemon-or-mount error becomes a per-program SKIP rather than a
# false FAIL — while a binary that is structurally valid but fails to *exec* (126)
# stays a real result and reddens the run.
CAN_RUN=0
RUN_KIND=""
case "$(uname -s)" in
    Linux)
        case "$(uname -m)" in
            x86_64 | amd64)
                CAN_RUN=1
                RUN_KIND=native
                ;;
        esac
        ;;
    Darwin)
        if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
            if docker pull --platform linux/amd64 alpine > /dev/null 2>&1; then
                CAN_RUN=1
                RUN_KIND=docker
            fi
        fi
        ;;
esac

# run_binary <name>: run $TMP/<name>, setting RAN=1 with CODE=<exit> and
# OUT=<stdout> on execution.  Leaves RAN=0 only for a genuine runtime/infra
# problem: no x86-64 runtime, or a Docker daemon/mount error (125 = daemon,
# 127 = command-not-found = mount).  A 126 (not executable) is a REAL linker
# result, so it is NOT bucketed as "could not run".
run_binary() {
    _name="$1"
    RAN=0
    CODE=0
    OUT=""
    [ "$CAN_RUN" = 1 ] || return
    if [ "$RUN_KIND" = native ]; then
        OUT="$("$TMP/$_name")"
        CODE=$?
        RAN=1
    else
        OUT="$(docker run --rm --platform linux/amd64 -v "$TMP:/w" alpine "/w/$_name")"
        _dc=$?
        case "$_dc" in
            125 | 127) ;;
            *) CODE=$_dc; RAN=1 ;;
        esac
    fi
}

run_binary exit42
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 42 ]; then
        echo "FAIL: exit42 expected exit 42, got $CODE" >&2
        exit 1
    fi
    echo "PASS: exit(42) ran and exited 42"
else
    echo "SKIP: exit42 not run here (no linux-x86-64 runtime) — build+structure verified"
fi

run_binary hello
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 0 ]; then
        echo "FAIL: hello expected exit 0, got $CODE" >&2
        exit 1
    fi
    if [ "$OUT" != "hi" ]; then
        echo "FAIL: hello expected output 'hi', got '$OUT'" >&2
        exit 1
    fi
    echo "PASS: hello ran, printed 'hi', and exited 0"
else
    echo "SKIP: hello not run here (no linux-x86-64 runtime) — build+structure verified"
fi
exit 0
