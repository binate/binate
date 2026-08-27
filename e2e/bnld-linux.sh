#!/bin/sh
# e2e/bnld-linux.sh — End-to-end proof that the Binate-native linker (bnld)
# produces a runnable static ELF64 x86-64 executable, with no clang/ld in the
# link: assemble a tiny exit(42) program with bnas, link it with bnld, verify the
# output is a static ELF64 ET_EXEC, and run it, checking the exit code.
#
# The run needs a linux-x86-64 environment: native on a Linux host, via Docker on
# a Mac host.  Where neither is available (a macOS CI runner without Docker), the
# assemble+link+structure check still runs and the execution is reported SKIP so
# the build/structure remains gated everywhere while the run is gated where it can
# happen (Linux CI, or a Docker-equipped dev host).
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

# ----- a tiny x86-64 program: exit(42) via the Linux exit syscall (rax=60) -----
cat > "$TMP/exit42.s" <<'EOF'
.arch x64
.section text
.global _start
_start:
	mov edi, 42
	mov eax, 60
	syscall
EOF

if ! "$BNAS" -arch x64 -o "$TMP/exit42.o" "$TMP/exit42.s" > "$TMP/asm.log" 2>&1; then
    echo "FAIL: bnas could not assemble exit42.s" >&2
    cat "$TMP/asm.log" >&2
    exit 1
fi
if ! "$BNLD" -o "$TMP/prog" "$TMP/exit42.o" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld could not link exit42.o" >&2
    cat "$TMP/link.log" >&2
    exit 1
fi

# ----- structure check: a static ELF64 ET_EXEC, owner-executable -----
magic="$(od -An -tx1 -N4 "$TMP/prog" | tr -d ' \n')"
if [ "$magic" != "7f454c46" ]; then
    echo "FAIL: output is not an ELF file (magic=$magic)" >&2
    exit 1
fi
class="$(od -An -tu1 -j4 -N1 "$TMP/prog" | tr -d ' \n')"
if [ "$class" != "2" ]; then
    echo "FAIL: output is not ELF64 (EI_CLASS=$class)" >&2
    exit 1
fi
etype="$(od -An -tu1 -j16 -N1 "$TMP/prog" | tr -d ' \n')"
if [ "$etype" != "2" ]; then
    echo "FAIL: output is not ET_EXEC (e_type=$etype)" >&2
    exit 1
fi
if [ ! -x "$TMP/prog" ]; then
    echo "FAIL: output is not owner-executable" >&2
    exit 1
fi
echo "PASS: bnld produced a static ELF64 x86-64 executable"

# ----- run it and check exit code 42 -----
# run_prog sets RAN=1 and CODE=<program exit> only when it actually executed the
# linked binary; it leaves RAN=0 ("could not run here") for a non-x86-64 host, no
# Docker, or a Docker infrastructure error (pull/mount/emulation) — none of which
# is the linker's fault, so those become SKIP rather than a false FAIL.  Using
# explicit flags (not an overloaded exit code) avoids colliding with a real exit.
RAN=0
CODE=0
run_prog() {
    case "$(uname -s)" in
        Linux)
            case "$(uname -m)" in
                x86_64 | amd64)
                    "$TMP/prog"
                    CODE=$?
                    RAN=1
                    ;;
            esac
            ;;
        Darwin)
            if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
                # Pre-pull so a Docker Hub / rate-limit failure is a SKIP, not a
                # FAIL; run only if the image is present.
                if docker pull --platform linux/amd64 alpine > /dev/null 2>&1; then
                    docker run --rm --platform linux/amd64 -v "$TMP:/w" alpine /w/prog
                    dc=$?
                    # 125/126/127 = docker daemon/exec/mount error (not the program).
                    case "$dc" in
                        125 | 126 | 127) ;;
                        *) CODE=$dc; RAN=1 ;;
                    esac
                fi
            fi
            ;;
    esac
}

run_prog
if [ "$RAN" = 0 ]; then
    echo "SKIP: no linux-x86-64 runtime here (host arch / no Docker) — build+structure verified"
    exit 0
fi
if [ "$CODE" = 42 ]; then
    echo "PASS: the linked program ran and exited 42"
    exit 0
fi
echo "FAIL: expected exit 42, got $CODE" >&2
exit 1
