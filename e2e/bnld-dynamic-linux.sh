#!/bin/sh
# e2e/bnld-dynamic-linux.sh — End-to-end proof that the Binate-native linker (bnld)
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_dyn.XXXXXX")"
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

# ----- assemble + dynamically link exit42 (calls libc exit; no raw syscall) -----
# `exit` is declared .global (undefined) so the assembler emits a call relocation
# against it; bnld -dynamic turns that into a libc import.
cat > "$TMP/exit42.s" <<'EOF'
.arch aarch64
.section text
.global _start
.global exit
_start:
	mov x0, #42
	bl exit
EOF
if ! "$BNAS" -target linux-aarch64 -o "$TMP/exit42.o" "$TMP/exit42.s" > "$TMP/asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble exit42" >&2
    cat "$TMP/asm.log" >&2
    exit 1
fi
if ! "$BNLD" -target linux-aarch64 -dynamic -o "$TMP/exit42_dyn" "$TMP/exit42.o" \
        > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld could not dynamically link exit42" >&2
    cat "$TMP/link.log" >&2
    exit 1
fi

# ----- structure check (host-side, runtime-independent) -----
# ELF magic.
magic="$(dd if="$TMP/exit42_dyn" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [ "$magic" != "7f454c46" ]; then
    echo "FAIL: exit42_dyn is not an ELF file (magic $magic)" >&2
    exit 1
fi
# The dynamic-linker path and the needed library must be present (PT_INTERP / DT_NEEDED).
if ! grep -q "/lib/ld-linux-aarch64.so.1" "$TMP/exit42_dyn"; then
    echo "FAIL: exit42_dyn has no PT_INTERP dynamic-linker path" >&2
    exit 1
fi
if ! grep -q "libc.so.6" "$TMP/exit42_dyn"; then
    echo "FAIL: exit42_dyn does not name libc.so.6 (DT_NEEDED)" >&2
    exit 1
fi
echo "PASS: bnld -dynamic produced a dynamically-linked aarch64 ELF (interp + libc.so.6)"

# ----- run it: natively where the host can, else via Docker/qemu -----
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

RAN=0
CODE=0
if [ "$CAN_RUN" = 1 ]; then
    if [ "$RUN_KIND" = native ]; then
        "$TMP/exit42_dyn"
        CODE=$?
        RAN=1
    else
        docker run --rm --platform linux/arm64 -v "$TMP:/w" debian:stable-slim /w/exit42_dyn
        _dc=$?
        # 125 = daemon error, 127 = mount/command-not-found: an infra problem, not a
        # linker result.  Anything else (including a real 126 not-executable) counts.
        case "$_dc" in
            125 | 127) ;;
            *) CODE=$_dc; RAN=1 ;;
        esac
    fi
fi

if [ "$RAN" = 1 ]; then
    if [ "$CODE" != 42 ]; then
        echo "FAIL: exit42_dyn expected exit 42, got $CODE" >&2
        exit 1
    fi
    echo "PASS: bnld-linked dynamic ELF called libc exit(42) and exited 42"
else
    echo "SKIP: exit42_dyn not run here (needs an aarch64 glibc Linux host, or" \
            "BINATE_E2E_DOCKER=1 for a local Docker run) — build+structure verified"
fi

echo "ALL PASS: bnld dynamic ELF linking (aarch64)"
