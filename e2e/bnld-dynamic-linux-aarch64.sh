#!/bin/sh
# e2e/bnld-dynamic-linux-aarch64.sh — End-to-end proof that the Binate-native linker (bnld)
# produces a RUNNABLE, DYNAMICALLY-linked aarch64 ELF that calls into libc, with no
# clang/ld in the link.  A program whose _start does `mov x0,#42 ; bl exit` is
# assembled with bnas and linked with `bnld -dynamic`: the undefined `exit` becomes a
# dynamic import from libc.so.6, resolved at load by /lib/ld-linux-aarch64.so.1, and
# libc's exit(42) ends the process — so the exit code proves the whole dynamic path
# (PT_INTERP, .dynamic, .plt/.got.plt, the JUMP_SLOT bound by ld.so).
#
# The build + link + structure check run everywhere (host-independent ELF byte
# generation).  The RUN needs a glibc linux/arm64 loader.  CI has no native aarch64
# Linux runner (the e2e matrix is x86-64 Linux + arm64 macOS), so the run happens under
# a glibc arm64 Docker image via qemu — but ONLY on a Linux CI lane, so it executes on
# exactly one CI platform (not duplicated on the macOS lane).  A default LOCAL run does
# NOT use Docker (it is heavyweight): it runs natively if the host can, else SKIPs —
# unless BINATE_E2E_DOCKER=1 opts into Docker.  A correct linker is never blamed on the
# environment, while a broken one (or output ld.so rejects) still reddens a host that
# runs it.
#
# Exit 0 on pass (including run-skipped); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_dyn_aa64.XXXXXX")"
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
# asm_link_dyn <name>: read a .s from stdin, assemble with bnas and link with
# `bnld -dynamic` to $TMP/<name>, then check the output is an ELF naming the dynamic
# linker + libc.so.6.  `exit`/`puts` are declared .global (undefined) so bnas emits
# call relocations against them; bnld -dynamic turns those into libc imports.
asm_link_dyn() {
    _name="$1"
    cat > "$TMP/$_name.s"
    if ! "$BNAS" -target linux-aarch64 -o "$TMP/$_name.o" "$TMP/$_name.s" \
            > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -target linux-aarch64 -dynamic -o "$TMP/$_name" "$TMP/$_name.o" \
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
    if ! grep -q "/lib/ld-linux-aarch64.so.1" "$TMP/$_name"; then
        echo "FAIL: $_name has no PT_INTERP dynamic-linker path" >&2
        exit 1
    fi
    if ! grep -q "libc.so.6" "$TMP/$_name"; then
        echo "FAIL: $_name does not name libc.so.6 (DT_NEEDED)" >&2
        exit 1
    fi
}

# ----- exit42: _start does `mov x0,#42 ; bl exit` — one libc import (exit). -----
asm_link_dyn exit42 <<'EOF'
.arch aarch64
.section text
.global _start
.global exit
_start:
	mov x0, #42
	bl exit
EOF
echo "PASS: exit42 links to a dynamically-linked aarch64 ELF (interp + libc.so.6)"

# ----- hello: pass a .rodata string (reached via ADRP+ADD, an internal relocation)
#       to libc puts, then exit 0 — exercises TWO imports (puts + exit), a data
#       argument, and stdio (which proves ld.so ran libc's init before _start). -----
asm_link_dyn hello <<'EOF'
.arch aarch64
.section rodata
msg:
	.asciz "hello from bnld"
.section text
.global _start
.global puts
.global exit
_start:
	adrp x0, msg
	add x0, x0, #:lo12:msg
	bl puts
	mov x0, #0
	bl exit
EOF
echo "PASS: hello links to a dynamically-linked aarch64 ELF (imports puts + exit)"

# ----- run: natively where the host can, else via Docker/qemu -----
# CI has no native aarch64 Linux runner (the e2e matrix is x86-64 Linux + arm64
# macOS), so the arm64 binary is run under a glibc arm64 Docker image via qemu — but
# ONLY on a Linux CI lane, so the run happens on exactly one CI platform and is not
# duplicated on the macOS lane.  Docker is deliberately NOT imposed on a default local
# run (it is heavyweight): a local box runs the binary only if it can natively, or if
# BINATE_E2E_DOCKER=1 explicitly opts into Docker.
CAN_RUN=0
RUN_KIND=""
if [ "$(uname -s)" = Linux ] && [ -e /lib/ld-linux-aarch64.so.1 ]; then
    # Native aarch64 Linux (or an x86-64 host with aarch64 multiarch/binfmt).
    CAN_RUN=1
    RUN_KIND=native
else
    # Docker/qemu is used on a Linux CI lane, or on an explicit local opt-in — never on
    # a default local run, and never on the macOS CI lane (so it is not duplicated).
    want_docker=0
    if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then want_docker=1; fi
    if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then want_docker=1; fi
    if [ "$want_docker" = 1 ] && command -v docker > /dev/null 2>&1 \
            && docker info > /dev/null 2>&1 \
            && docker run --rm --platform linux/arm64 debian:stable-slim true > /dev/null 2>&1; then
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
        OUT="$(docker run --rm --platform linux/arm64 -v "$TMP:/w" debian:stable-slim "/w/$_name")"
        _dc=$?
        case "$_dc" in
            125 | 127) ;;
            *) CODE=$_dc; RAN=1 ;;
        esac
    fi
}

_skip_note="needs an aarch64 glibc Linux host, or BINATE_E2E_DOCKER=1 for a local Docker run"

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

echo "ALL PASS: bnld dynamic ELF linking (aarch64)"
