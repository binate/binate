#!/bin/sh
# e2e/bnld-archive-linux.sh — End-to-end proof that the Binate-native linker (bnld)
# links a program against a static `.a` archive, extracting the needed member by
# symbol — with no clang/ld in the link.
#
# Two objects are assembled with bnas and put in a GNU archive with the system `ar`:
#   * helper — exits 42.
#   * unused — never referenced.
# A `main` that calls `helper` is linked against the archive with bnld; the linker
# must pull in the `helper` member (to resolve the call) and leave `unused` out, and
# the resulting static ELF64 executable runs and exits 42.
#
# Runs only on a native x86-64 Linux host (system `ar` there writes the GNU/SysV
# format bnld reads, and the binary runs natively) and skips early everywhere else —
# no Docker/qemu, and macOS `ar` writes the BSD format bnld does not read.
#
# Exit 0 on pass (including the early skip); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

if [ "$(uname -s)" != Linux ] || { [ "$(uname -m)" != x86_64 ] && [ "$(uname -m)" != amd64 ]; }; then
    echo "SKIP: archive-link e2e runs only on native x86-64 Linux (needs GNU ar)"
    exit 0
fi
if ! command -v ar > /dev/null 2>&1; then
    echo "SKIP: no ar available to build the test archive"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_arlink.XXXXXX")"
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

asm() {
    _name="$1"
    if ! "$BNAS" -arch x64 -o "$TMP/$_name.o" "$TMP/$_name.s" > "$TMP/$_name.asm.log" 2>&1; then
        echo "FAIL: bnas could not assemble $_name" >&2
        cat "$TMP/$_name.asm.log" >&2
        exit 1
    fi
}

# helper exits 42; unused is never referenced; main calls helper.
cat > "$TMP/helper.s" <<'EOF'
.arch x64
.section text
.global helper
helper:
	mov edi, 42
	mov eax, 60
	syscall
EOF
cat > "$TMP/unused.s" <<'EOF'
.arch x64
.section text
.global unused
unused:
	ret
EOF
cat > "$TMP/main.s" <<'EOF'
.arch x64
.section text
.global _start
.global helper
_start:
	call helper
EOF
asm helper
asm unused
asm main

# Bundle helper.o + unused.o into a GNU archive.
rm -f "$TMP/lib.a"
if ! ar rcs "$TMP/lib.a" "$TMP/helper.o" "$TMP/unused.o" > "$TMP/ar.log" 2>&1; then
    echo "FAIL: ar could not build the archive" >&2
    cat "$TMP/ar.log" >&2
    exit 1
fi

# Link main.o against the archive: bnld must extract the helper member.
if ! "$BNLD" -o "$TMP/prog" "$TMP/main.o" "$TMP/lib.a" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld could not link against the archive" >&2
    cat "$TMP/link.log" >&2
    exit 1
fi

# Structure check: static, owner-executable ELF64 ET_EXEC EM_X86_64.
P="$TMP/prog"
if [ "$(od -An -tx1 -N4 "$P" | tr -d ' \n')" != "7f454c46" ]; then
    echo "FAIL: output is not an ELF file" >&2; exit 1
fi
if [ "$(od -An -tu1 -j4 -N1 "$P" | tr -d ' \n')" != "2" ]; then
    echo "FAIL: not ELF64" >&2; exit 1
fi
if [ "$(od -An -tu1 -j16 -N1 "$P" | tr -d ' \n')" != "2" ]; then
    echo "FAIL: not ET_EXEC" >&2; exit 1
fi
[ -x "$P" ] || { echo "FAIL: output not owner-executable" >&2; exit 1; }
echo "PASS: a program links against a static archive (helper member extracted)"

# Run it: the exit code is helper's (42).
"$P"
CODE=$?
if [ "$CODE" != 42 ]; then
    echo "FAIL: expected exit 42 from the archive's helper, got $CODE" >&2
    exit 1
fi
echo "PASS: the archive-linked program ran and exited 42 (helper extracted from lib.a)"

# ----- transitive extraction via -L/-l: main2 calls entrypt (in the archive), which
#       calls helper2 (also in the archive) — so bnld must pull entrypt AND, from
#       entrypt's own reference, helper2, while leaving unused2 out. -----
cat > "$TMP/helper2.s" <<'EOF'
.arch x64
.section text
.global helper2
helper2:
	mov edi, 42
	mov eax, 60
	syscall
EOF
cat > "$TMP/entrypt.s" <<'EOF'
.arch x64
.section text
.global entrypt
.global helper2
entrypt:
	call helper2
EOF
cat > "$TMP/unused2.s" <<'EOF'
.arch x64
.section text
.global unused2
unused2:
	ret
EOF
cat > "$TMP/main2.s" <<'EOF'
.arch x64
.section text
.global _start
.global entrypt
_start:
	call entrypt
EOF
asm helper2
asm entrypt
asm unused2
asm main2

mkdir -p "$TMP/libs"
rm -f "$TMP/libs/libstuff.a"
if ! ar rcs "$TMP/libs/libstuff.a" "$TMP/entrypt.o" "$TMP/helper2.o" "$TMP/unused2.o" \
        > "$TMP/ar2.log" 2>&1; then
    echo "FAIL: ar could not build libstuff.a" >&2
    cat "$TMP/ar2.log" >&2
    exit 1
fi

# Link with -L/-l (the way ld is invoked); bnld resolves libstuff.a from -L.
if ! "$BNLD" -o "$TMP/prog2" "$TMP/main2.o" -L "$TMP/libs" -l stuff > "$TMP/link2.log" 2>&1; then
    echo "FAIL: bnld could not link with -L/-l" >&2
    cat "$TMP/link2.log" >&2
    exit 1
fi
if [ ! -x "$TMP/prog2" ]; then
    echo "FAIL: -L/-l output is not owner-executable" >&2; exit 1
fi
echo "PASS: -L/-l links against a library (entrypt + transitively helper2 extracted)"

"$TMP/prog2"
CODE2=$?
if [ "$CODE2" != 42 ]; then
    echo "FAIL: -L/-l program expected exit 42 (transitive helper2), got $CODE2" >&2
    exit 1
fi
echo "PASS: the -L/-l program ran and exited 42 (transitive extraction to a fixpoint)"
exit 0
