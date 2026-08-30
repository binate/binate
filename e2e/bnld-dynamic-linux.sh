#!/bin/sh
# e2e/bnld-dynamic-linux.sh — End-to-end proof that the Binate-native linker (bnld)
# produces a RUNNABLE, DYNAMICALLY-linked x86-64 ELF that calls into libc, with no
# clang/ld in the link.  Programs are assembled with bnas and linked with
# `bnld -target linux-x64 -dynamic`: undefined externals (exit, puts) become dynamic
# imports from libc.so.6, resolved at load by /lib64/ld-linux-x86-64.so.2.
#   * exit42 — `mov edi,42 ; call exit` → libc exit(42); the exit code proves the path.
#   * hello  — passes a .rodata string (via a RIP-relative lea, an internal relocation)
#              to libc puts, then exit(0): TWO imports, a data argument, and stdio.
#   * datum  — GOT-loads the libc DATA symbol `stdout` (mov rax,[rip+stdout@GOTPCREL])
#              and exits 42 iff non-null: the data-import (.got + GLOB_DAT) path — the
#              __c_global mechanism — plus `exit` (PLT), so also the mixed PLT+GOT case.
#
# This is the x86-64 sibling of bnld-dynamic-linux-aarch64.sh.  The build + link +
# structure check run everywhere; the RUN happens NATIVELY on an x86-64 Linux host —
# which is the standard CI Linux runner, so CI runs it with no Docker at all.  A
# default local run on a non-x86-64 host SKIPs (Docker is heavyweight and not imposed);
# BINATE_E2E_DOCKER=1, or a Linux CI lane, opts into a linux/amd64 container.
#
# Exit 0 on pass (including run-skipped); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_dyn_x64.XXXXXX")"
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

# ----- helper: assemble + dynamically link + structure-check a program -----
# asm_link_dyn <name>: read a .s from stdin, assemble with bnas (-arch x64) and link
# with `bnld -target linux-x64 -dynamic` to $TMP/<name>, then check the output is an
# ELF naming the dynamic linker + libc.so.6.  `exit`/`puts` are declared .global
# (undefined) so bnas emits call relocations against them; -dynamic makes them imports.
asm_link_dyn() {
    _name="$1"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -arch x64 -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -target linux-x64 -dynamic -o "$TMP/$_name" "$TMP/$_name.o" \
            > "$TMP/$_name.link.log" 2>&1; then
        echo "FAIL: bnld could not dynamically link $_name" >&2
        cat "$TMP/$_name.link.log" >&2
        exit 1
    fi
    _magic="$(od -An -tx1 -N4 "$TMP/$_name" | tr -d ' \n')"
    if [ "$_magic" != "7f454c46" ]; then
        echo "FAIL: $_name is not an ELF file (magic $_magic)" >&2
        exit 1
    fi
    if ! grep -q "/lib64/ld-linux-x86-64.so.2" "$TMP/$_name"; then
        echo "FAIL: $_name has no PT_INTERP dynamic-linker path" >&2
        exit 1
    fi
    if ! grep -q "libc.so.6" "$TMP/$_name"; then
        echo "FAIL: $_name does not name libc.so.6 (DT_NEEDED)" >&2
        exit 1
    fi
}

# ----- exit42: `mov edi,42 ; call exit` — one libc import (exit). -----
asm_link_dyn exit42 <<'EOF'
.arch x64
.section text
.global _start
.global exit
_start:
	mov edi, 42
	call exit
EOF
echo "PASS: exit42 links to a dynamically-linked x86-64 ELF (interp + libc.so.6)"

# ----- hello: pass a .rodata string (reached via a RIP-relative lea, an internal
#       relocation) to libc puts, then exit 0 — TWO imports (puts + exit), a data
#       argument, and stdio (which proves ld.so ran libc's init before _start). -----
asm_link_dyn hello <<'EOF'
.arch x64
.section rodata
msg:
	.asciz "hello from bnld"
.section text
.global _start
.global puts
.global exit
_start:
	lea rdi, [rip + msg]
	call puts
	mov edi, 0
	call exit
EOF
echo "PASS: hello links to a dynamically-linked x86-64 ELF (imports puts + exit)"

# ----- datum: GOT-load a libc DATA symbol (stdout) via `mov rax,[rip+stdout@GOTPCREL]`
#       and exit 42 iff it is non-null — exercises a GLOB_DAT data import (the
#       __c_global path), distinct from the PLT/JUMP_SLOT function imports above.
#       `stdout` (a FILE*) is a static libc datum ld.so relocates when it loads libc,
#       so it is non-null even without __libc_start_main.  `exit` is a PLT import, so
#       this is the mixed PLT+GOT case. -----
asm_link_dyn datum <<'EOF'
.arch x64
.section text
.global _start
.global stdout
.global exit
_start:
	mov rax, [rip + stdout@GOTPCREL]
	mov rax, [rax]
	test rax, rax
	jz Lzero
	mov edi, 42
	call exit
Lzero:
	mov edi, 0
	call exit
EOF
echo "PASS: datum links to a dynamically-linked x86-64 ELF (GOT data import: stdout)"

# ----- run: natively on an x86-64 Linux host (the CI Linux runner — no Docker) -----
# A default local run on a non-x86-64 host SKIPs; Docker (linux/amd64) is used only on
# a Linux CI lane or an explicit BINATE_E2E_DOCKER=1 opt-in, never a default local run.
CAN_RUN=0
RUN_KIND=""
if [ "$(uname -s)" = Linux ] && { [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = amd64 ]; }; then
    CAN_RUN=1
    RUN_KIND=native
else
    want_docker=0
    if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then want_docker=1; fi
    if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then want_docker=1; fi
    if [ "$want_docker" = 1 ] && command -v docker > /dev/null 2>&1 \
            && docker info > /dev/null 2>&1 \
            && docker run --rm --platform linux/amd64 debian:stable-slim true > /dev/null 2>&1; then
        CAN_RUN=1
        RUN_KIND=docker
    fi
fi

# run_dyn <name>: run $TMP/<name>, setting RAN=1 with CODE=<exit> and OUT=<stdout> on
# execution.  A Docker daemon (125) / mount (127) error leaves RAN=0 (infra, not a
# linker result); a real 126 (not executable) counts.
run_dyn() {
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
        OUT="$(docker run --rm --platform linux/amd64 -v "$TMP:/w" debian:stable-slim "/w/$_name")"
        _dc=$?
        case "$_dc" in
            125 | 127) ;;
            *) CODE=$_dc; RAN=1 ;;
        esac
    fi
}

_skip_note="needs an x86-64 Linux host, or BINATE_E2E_DOCKER=1 for a local Docker run"

run_dyn exit42
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 42 ]; then
        echo "FAIL: exit42 expected exit 42, got $CODE" >&2
        exit 1
    fi
    echo "PASS: exit42 ran — libc exit(42) exited 42"
else
    echo "SKIP: exit42 not run here ($_skip_note) — build+structure verified"
fi

run_dyn hello
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 0 ]; then
        echo "FAIL: hello expected exit 0, got $CODE" >&2
        exit 1
    fi
    if [ "$OUT" != "hello from bnld" ]; then
        echo "FAIL: hello expected output 'hello from bnld', got '$OUT'" >&2
        exit 1
    fi
    echo "PASS: hello ran — printed via libc puts and exited 0"
else
    echo "SKIP: hello not run here ($_skip_note) — build+structure verified"
fi

run_dyn datum
if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 42 ]; then
        echo "FAIL: datum expected exit 42 (libc stdout bound non-null via GLOB_DAT), got $CODE" >&2
        exit 1
    fi
    echo "PASS: datum ran — GOT-loaded libc stdout (bound via GLOB_DAT) and exited 42"
else
    echo "SKIP: datum not run here ($_skip_note) — build+structure verified"
fi

echo "ALL PASS: bnld dynamic ELF linking (x86-64)"
