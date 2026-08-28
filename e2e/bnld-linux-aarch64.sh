#!/bin/sh
# e2e/bnld-linux-aarch64.sh — End-to-end proof that the Binate-native linker
# (bnld) produces RUNNABLE static ELF64 AArch64 executables, with no clang/ld in
# the link.  Two programs are assembled with bnas (-arch aarch64), linked with
# bnld (-target linux-aarch64), checked to be static ELF64 ET_EXEC EM_AARCH64, and
# run:
#   * exit42 — exits 42 (pins the exit-code path; no relocations).
#   * hello  — writes "hi\n" then exits 0 (reaches a .rodata string via `adr`, so
#              an R_AARCH64_ADR_PREL_LO21 relocation from .text into .rodata is
#              applied and exercised at run time).
#
# The run needs a way to execute linux/arm64.  CI has no native aarch64 Linux runner,
# so the run happens under Docker/qemu — but ONLY on a Linux CI lane, so it executes on
# exactly one CI platform (not duplicated on the macOS lane).  A default LOCAL run does
# NOT use Docker (heavyweight): it runs natively on an aarch64 Linux host, else SKIPs —
# unless BINATE_E2E_DOCKER=1 opts into Docker.  Where it can't run, the assemble+link+
# structure check still gates and the run SKIPs, so a correct linker is never blamed on
# the environment while a broken one still reddens a host that runs it.
#
# Exit 0 on pass (including run-skipped); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_aa64.XXXXXX")"
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

# check_elf <path> <name>: the linked output must be a static ELF64 ET_EXEC for
# EM_AARCH64 (183) that is owner-executable.
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
    # e_machine is a 2-byte LE field at offset 18; EM_AARCH64 = 183 (0x00B7).
    _mach_lo="$(od -An -tu1 -j18 -N1 "$_p" | tr -d ' \n')"
    _mach_hi="$(od -An -tu1 -j19 -N1 "$_p" | tr -d ' \n')"
    if [ "$_mach_lo" != "183" ] || [ "$_mach_hi" != "0" ]; then
        echo "FAIL: $_n is not EM_AARCH64 (e_machine=$_mach_hi,$_mach_lo)" >&2
        exit 1
    fi
    if [ ! -x "$_p" ]; then
        echo "FAIL: $_n is not owner-executable" >&2
        exit 1
    fi
}

# asm_link <name>: read a .s from stdin, assemble with bnas (aarch64) and link with
# bnld (-target linux-aarch64) to $TMP/<name>, and structure-check the result.
# FAILs the whole test on error.
asm_link() {
    _name="$1"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -target linux-aarch64 -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -target linux-aarch64 -o "$TMP/$_name" "$TMP/$_name.o" > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld could not link $_name" >&2
        cat "$TMP/$_name.link.log" >&2
        exit 1
    fi
    check_elf "$TMP/$_name" "$_name"
}

# ----- exit42: exits 42 (no relocations).  x8 = __NR_exit (93), x0 = code. -----
asm_link exit42 <<'EOF'
.arch aarch64
.section text
.global _start
_start:
	mov x0, #42
	mov x8, #93
	svc #0
EOF
echo "PASS: exit(42) links to a static ELF64 aarch64 executable"

# ----- hello: writes "hi\n" then exits 0.  `adr` reaches msg in .rodata via an
#       R_AARCH64_ADR_PREL_LO21 relocation.  x8 = __NR_write (64) / __NR_exit
#       (93). -----
asm_link hello <<'EOF'
.arch aarch64
.section rodata
msg:
	.ascii "hi\n"
.section text
.global _start
_start:
	mov x0, #1
	adr x1, msg
	mov x2, #3
	mov x8, #64
	svc #0
	mov x0, #0
	mov x8, #93
	svc #0
EOF
echo "PASS: hello links to a static ELF64 aarch64 executable"

# ----- hellopg: same as hello, but reaches msg with the ADRP+ADD pair (the way
#       to address data beyond ADR's ±1MB), so R_AARCH64_ADR_PREL_PG_HI21 and
#       R_AARCH64_ADD_ABS_LO12_NC are both applied and exercised at run time. -----
asm_link hellopg <<'EOF'
.arch aarch64
.section rodata
msg2:
	.ascii "hi\n"
.section text
.global _start
_start:
	mov x0, #1
	adrp x1, msg2
	add x1, x1, #:lo12:msg2
	mov x2, #3
	mov x8, #64
	svc #0
	mov x0, #0
	mov x8, #93
	svc #0
EOF
echo "PASS: hellopg links to a static ELF64 aarch64 executable"

# ----- dataval: loads an 8-byte value from .data via ADRP+LDR and exits with it
#       (0x2a = 42), so R_AARCH64_LDST64_ABS_LO12_NC is applied and exercised at run
#       time — and .data being writable, this also runs the two-segment (W^X) image.
asm_link dataval <<'EOF'
.arch aarch64
.section data
val:
	.uint64 42
.section text
.global _start
_start:
	adrp x1, val
	ldr x0, [x1, #:lo12:val]
	mov x8, #93
	svc #0
EOF
echo "PASS: dataval links to a static ELF64 aarch64 executable"

# ----- run the programs if a linux-aarch64 runtime is available -----
# Detect the runtime once (and pull the image on the Docker path) so a missing
# runtime / Docker daemon-or-mount error becomes a per-program SKIP rather than a
# false FAIL — while a binary that is structurally valid but fails to *exec* (126)
# stays a real result and reddens the run.
CAN_RUN=0
RUN_KIND=""
if [ "$(uname -s)" = Linux ] && { [ "$(uname -m)" = aarch64 ] || [ "$(uname -m)" = arm64 ]; }; then
    # Native aarch64 Linux: run the binaries directly.
    CAN_RUN=1
    RUN_KIND=native
else
    # CI has no native aarch64 Linux runner, so arm64 is run under Docker/qemu — but
    # ONLY on a Linux CI lane, so the run happens on exactly one CI platform and is not
    # duplicated on the macOS lane.  Docker is deliberately NOT imposed on a default
    # local run (it is heavyweight): a local box runs only natively or on an explicit
    # BINATE_E2E_DOCKER=1 opt-in.  Preflight with a real arm64 `true` (not just a pull):
    # only if it exits 0 can this environment run aarch64, so a later non-zero exit is a
    # genuine linker result; a preflight failure (no qemu/binfmt, daemon/mount error) is
    # SKIPped rather than blamed on the linker.
    want_docker=0
    if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then want_docker=1; fi
    if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then want_docker=1; fi
    if [ "$want_docker" = 1 ] && command -v docker > /dev/null 2>&1 \
            && docker info > /dev/null 2>&1 \
            && docker run --rm --platform linux/arm64 alpine true > /dev/null 2>&1; then
        CAN_RUN=1
        RUN_KIND=docker
    fi
fi

# run_binary <name>: run $TMP/<name>, setting RAN=1 with CODE=<exit> and
# OUT=<stdout> on execution.  Leaves RAN=0 only for a genuine runtime/infra
# problem: no aarch64 runtime, or a Docker daemon/mount error (125 = daemon,
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
        OUT="$(docker run --rm --platform linux/arm64 -v "$TMP:/w" alpine "/w/$_name")"
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
    echo "SKIP: exit42 not run here (no native aarch64 Linux; set BINATE_E2E_DOCKER=1 for a local Docker run) — build+structure verified"
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
    echo "SKIP: hello not run here (no native aarch64 Linux; set BINATE_E2E_DOCKER=1 for a local Docker run) — build+structure verified"
fi

run_binary hellopg
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 0 ]; then
        echo "FAIL: hellopg expected exit 0, got $CODE" >&2
        exit 1
    fi
    if [ "$OUT" != "hi" ]; then
        echo "FAIL: hellopg expected output 'hi', got '$OUT'" >&2
        exit 1
    fi
    echo "PASS: hellopg ran (ADRP+ADD reached .rodata), printed 'hi', exited 0"
else
    echo "SKIP: hellopg not run here (no native aarch64 Linux; set BINATE_E2E_DOCKER=1 for a local Docker run) — build+structure verified"
fi

run_binary dataval
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 42 ]; then
        echo "FAIL: dataval expected exit 42 (value from .data via ADRP+LDR), got $CODE" >&2
        exit 1
    fi
    echo "PASS: dataval ran (ADRP+LDR loaded from .data), exited 42"
else
    echo "SKIP: dataval not run here (no native aarch64 Linux; set BINATE_E2E_DOCKER=1 for a local Docker run) — build+structure verified"
fi
exit 0
