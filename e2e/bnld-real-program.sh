#!/bin/sh
# e2e/bnld-real-program.sh — End-to-end proof that the Binate-native linker (bnld)
# links a REAL bnc-compiled program: no ld in the link.
#
# A trivial Binate program is compiled to ELF objects (the main module plus the
# auto-pulled runtime packages), a small hermetic shim supplies `_start` and the
# handful of libc symbols the runtime references (malloc/calloc/free/write/abort)
# with a bump allocator + syscalls, and bnld links the whole object graph into one
# static ELF64 executable.  The program's exit code is what its bnc-compiled
# `compute()` returns — the sum of a managed slice it allocates and fills at run
# time (42) — so a correct run proves real compiled Binate code, INCLUDING the
# runtime memory path (MakeManagedSlice -> malloc, bounds checks, refcount), was
# linked and executed.
#
# Done for bnc's NATIVE x86-64 backend, and (when clang is present) for the LLVM
# backend, whose objects load symbol addresses via the GOT (R_X86_64_REX_GOTPCRELX)
# — which bnld relaxes to a direct lea.  The mangled compute()/bn_entry symbols are
# backend-independent, so the same shim links both.  The LLVM step additionally
# LINKS (but does not run, on an x86-64 host) the aarch64 LLVM objects, exercising
# the aarch64 GOT relaxation on real clang output.  clang is used only to compile;
# the LINK is always bnld, never ld.
#
# COST/POLICY: this is the heaviest bnld e2e — it builds bnc (the others build
# only bnas+bnld).  Its unique value is proving bnld links REAL bnc output and the
# result RUNS, which is only realizable on a native x86-64 Linux host (no
# Docker/qemu — those are too heavyweight).  So the whole body runs ONLY there;
# on any other host it SKIPs early, before building anything.  bnld's linking is
# already exercised on the other lanes by bnld-linux.sh, so nothing is lost.  (A
# future arm64-macOS variant should link a Mach-O arm64 build and run it natively
# — that needs bnld's Mach-O support first.)
#
# Exit 0 on pass (including the early skip); non-zero on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

# Run only on a native x86-64 Linux host; skip early everywhere else so no
# heavyweight build/compile/link happens where the program could not be run.
if [ "$(uname -s)" != Linux ] || { [ "$(uname -m)" != x86_64 ] && [ "$(uname -m)" != amd64 ]; }; then
    echo "SKIP: real-program link e2e runs only on native x86-64 Linux"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_realprog.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
OBJ="$TMP/obj"
mkdir -p "$OBJ"

# ----- build bnc + bnas + bnld from the current tree -----
build_tool() {
    _name="$1"
    if ! "$BINATE_DIR/scripts/build-$_name.sh" -o "$TMP/$_name" > "$TMP/build_$_name.log" 2>&1; then
        echo "FAIL: could not build $_name" >&2
        cat "$TMP/build_$_name.log" >&2
        exit 1
    fi
}
build_tool bnc
build_tool bnas
build_tool bnld
BNC="$TMP/bnc"
BNAS="$TMP/bnas"
BNLD="$TMP/bnld"

# nm is needed to discover the compiler-mangled name of `compute` (rather than
# hard-coding a mangling that could change).  Any binutils/llvm nm works.
NM="$(command -v nm || command -v llvm-nm || true)"
if [ -z "$NM" ]; then
    echo "SKIP: no nm available to read the object symbols" >&2
    exit 0
fi

# ----- the Binate program.  compute() allocates a managed slice, fills it in a
# bounds-checked loop, and sums it (2+4+6+8+10+12 = 42) — so the linked binary
# exercises the runtime's memory path at run time (MakeManagedSlice -> malloc,
# indexed-access bounds checks, refcount cleanup), not just static init.  main is
# empty; the exit code is compute()'s computed sum. -----
cat > "$TMP/tiny.bn" <<'EOF'
package "main"

func compute() int {
	var s @[]int = make_slice(int, 6)
	for i := 0; i < 6; i++ {
		s[i] = (i + 1) * 2
	}
	var sum int = 0
	for i := 0; i < 6; i++ {
		sum = sum + s[i]
	}
	return sum
}

func main() {
}
EOF

# ----- compile with the native x86-64 backend (ELF objects) -----
# The package search paths come from binate-paths.sh (self-locating to this repo),
# fed to bnc via its BINATE_PACKAGE_{INTERFACE,IMPL}_PATH environment variables.
eval "$(sh "$BINATE_DIR/scripts/binate-paths.sh")"
BINATE_PACKAGE_INTERFACE_PATH="$BINATE_I"
BINATE_PACKAGE_IMPL_PATH="$BINATE_L"
export BINATE_PACKAGE_INTERFACE_PATH BINATE_PACKAGE_IMPL_PATH
if ! "$BNC" --backend native --target x86_64-linux --build-dir "$OBJ" -c -o "$OBJ/tiny" \
        "$TMP/tiny.bn" > "$TMP/compile.log" 2>&1; then
    echo "FAIL: bnc could not compile the program" >&2
    cat "$TMP/compile.log" >&2
    exit 1
fi
if [ ! -f "$OBJ/main.o" ]; then
    echo "FAIL: bnc did not emit main.o" >&2
    ls -l "$OBJ" >&2
    exit 1
fi

# Discover the mangled name of compute() and of the program entry.
COMPUTE_SYM="$("$NM" "$OBJ/main.o" 2>/dev/null | awk '$2=="T" && $3 ~ /_compute$/ {print $3; exit}')"
if [ -z "$COMPUTE_SYM" ]; then
    echo "FAIL: could not find the compute() symbol in main.o" >&2
    "$NM" "$OBJ/main.o" >&2
    exit 1
fi

# ----- hermetic shim: _start + the libc symbols the runtime references.
# malloc is a bump allocator over a .bss arena; calloc reuses it (the arena is
# zero-initialized and never freed); free is a no-op; write/abort are syscalls.
# _start runs the program's init+main (bn_entry, which returns) then exits with
# compute()'s value. -----
cat > "$TMP/shim.s" <<EOF
.arch x64

.global bn_entry
.global $COMPUTE_SYM

.section bss
heap_base:
	.zero 4194304

.section data
heap_off:
	.uint64 0

.section text
.global _start
_start:
	call bn_entry
	call $COMPUTE_SYM
	mov rdi, rax
	mov eax, 60
	syscall

.global malloc
malloc:
	add rdi, 15
	and rdi, -16
	mov rsi, [rip + heap_off]
	lea rax, [rip + heap_base]
	add rax, rsi
	add rsi, rdi
	mov [rip + heap_off], rsi
	ret

.global calloc
calloc:
	imul rdi, rsi
	call malloc
	ret

.global free
free:
	ret

.global write
write:
	mov eax, 1
	syscall
	ret

.global abort
abort:
	mov edi, 134
	mov eax, 60
	syscall
EOF
if ! "$BNAS" -arch x64 -o "$TMP/shim.o" "$TMP/shim.s" > "$TMP/shim.log" 2>&1; then
    echo "FAIL: bnas could not assemble the shim" >&2
    cat "$TMP/shim.log" >&2
    exit 1
fi

# ----- link the whole object graph with bnld -----
if ! "$BNLD" -o "$TMP/prog" "$TMP/shim.o" "$OBJ"/*.o > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnld could not link the program" >&2
    cat "$TMP/link.log" >&2
    exit 1
fi

# ----- structure check: a static, owner-executable ELF64 ET_EXEC EM_X86_64 with
# two W^X segments (R+X then R+W). -----
byte() { od -An -tu1 -j"$2" -N1 "$1" | tr -d ' \n'; }
u16le() { _lo="$(byte "$1" "$2")"; _hi="$(byte "$1" $(($2 + 1)))"; echo $((_lo + _hi * 256)); }
P="$TMP/prog"
if [ "$(od -An -tx1 -N4 "$P" | tr -d ' \n')" != "7f454c46" ]; then
    echo "FAIL: output is not an ELF file" >&2; exit 1
fi
[ "$(byte "$P" 4)" = 2 ] || { echo "FAIL: not ELF64" >&2; exit 1; }
[ "$(u16le "$P" 16)" = 2 ] || { echo "FAIL: not ET_EXEC" >&2; exit 1; }
[ "$(u16le "$P" 18)" = 62 ] || { echo "FAIL: not EM_X86_64" >&2; exit 1; }
[ -x "$P" ] || { echo "FAIL: output not owner-executable" >&2; exit 1; }
[ "$(u16le "$P" 56)" = 2 ] || { echo "FAIL: expected two PT_LOAD segments" >&2; exit 1; }
# phdr0 p_flags at 64+4, phdr1 at 64+56+4 (PF_X=1,PF_W=2,PF_R=4): R+X=5, R+W=6.
[ "$(byte "$P" 68)" = 5 ] || { echo "FAIL: first segment should be R+X (5)" >&2; exit 1; }
[ "$(byte "$P" 124)" = 6 ] || { echo "FAIL: second segment should be R+W (6)" >&2; exit 1; }
echo "PASS: a real bnc program links to a static ELF64 x86-64 W^X executable"

# ----- run it (this host is native x86-64 Linux, gated at the top) -----
"$P"
CODE=$?
if [ "$CODE" != 42 ]; then
    echo "FAIL: program expected exit 42 (compute()), got $CODE" >&2
    exit 1
fi
echo "PASS: the bnld-linked bnc program ran and exited 42 (compute() over a heap slice)"

# ----- also link the SAME program compiled with the LLVM/clang backend, if clang is
# available.  Those objects load symbol addresses via the GOT
# (R_X86_64_REX_GOTPCRELX), which bnld relaxes to a direct lea; the shim above (same
# backend-independent compute()/bn_entry symbols) links them unchanged. -----
if command -v clang > /dev/null 2>&1; then
    OBJL="$TMP/obj_llvm"
    mkdir -p "$OBJL"
    if ! "$BNC" --target x86_64-linux --build-dir "$OBJL" -c -o "$OBJL/tiny" \
            "$TMP/tiny.bn" > "$TMP/compile_llvm.log" 2>&1; then
        echo "FAIL: bnc (LLVM backend) could not compile the program" >&2
        cat "$TMP/compile_llvm.log" >&2
        exit 1
    fi
    if ! "$BNLD" -o "$TMP/prog_llvm" "$TMP/shim.o" "$OBJL"/*.o > "$TMP/link_llvm.log" 2>&1; then
        echo "FAIL: bnld could not link the LLVM-backend objects" >&2
        cat "$TMP/link_llvm.log" >&2
        exit 1
    fi
    PL="$TMP/prog_llvm"
    if [ "$(od -An -tx1 -N4 "$PL" | tr -d ' \n')" != "7f454c46" ]; then
        echo "FAIL: LLVM-backend output is not an ELF file" >&2; exit 1
    fi
    [ "$(u16le "$PL" 18)" = 62 ] || { echo "FAIL: LLVM-backend output not EM_X86_64" >&2; exit 1; }
    [ -x "$PL" ] || { echo "FAIL: LLVM-backend output not owner-executable" >&2; exit 1; }
    echo "PASS: a bnc program built with the LLVM backend links with bnld (GOTPCRELX relaxed)"
    "$PL"
    CODEL=$?
    if [ "$CODEL" != 42 ]; then
        echo "FAIL: LLVM-backend program expected exit 42, got $CODEL" >&2
        exit 1
    fi
    echo "PASS: the bnld-linked LLVM-backend program ran and exited 42"

    # Also LINK (not run — this host is x86-64) the aarch64 LLVM-backend objects, so
    # the aarch64 GOT relaxation (ADRP+LDR -> ADRP+ADD) is exercised on real clang
    # output in CI.  clang compiles aarch64 .ll -> .o without a sysroot; the run is
    # covered out-of-band / by the aarch64 relocation unit tests.
    OBJA="$TMP/obj_aa64"
    mkdir -p "$OBJA"
    if ! "$BNC" --target aarch64-linux --build-dir "$OBJA" -c -o "$OBJA/tiny" \
            "$TMP/tiny.bn" > "$TMP/compile_aa64.log" 2>&1; then
        echo "FAIL: bnc (LLVM backend, aarch64) could not compile the program" >&2
        cat "$TMP/compile_aa64.log" >&2
        exit 1
    fi
    # A minimal aarch64 shim: it only needs to DEFINE _start + the libc symbols so
    # the graph links (it is not run, so the stubs need not work).
    cat > "$TMP/shim_aa64.s" <<'AAEOF'
.arch aarch64
.global bn_entry
.section text
.global _start
_start:
	bl bn_entry
	mov x8, #93
	svc #0
.global malloc
malloc:
	ret
.global calloc
calloc:
	ret
.global free
free:
	ret
.global write
write:
	ret
.global abort
abort:
	ret
AAEOF
    if ! "$BNAS" -target linux-aarch64 -o "$TMP/shim_aa64.o" "$TMP/shim_aa64.s" \
            > "$TMP/shim_aa64.log" 2>&1; then
        echo "FAIL: bnas could not assemble the aarch64 shim" >&2
        cat "$TMP/shim_aa64.log" >&2
        exit 1
    fi
    if ! "$BNLD" -target linux-aarch64 -o "$TMP/prog_aa64" "$TMP/shim_aa64.o" "$OBJA"/*.o \
            > "$TMP/link_aa64.log" 2>&1; then
        echo "FAIL: bnld could not link the aarch64 LLVM-backend objects" >&2
        cat "$TMP/link_aa64.log" >&2
        exit 1
    fi
    PA="$TMP/prog_aa64"
    if [ "$(od -An -tx1 -N4 "$PA" | tr -d ' \n')" != "7f454c46" ]; then
        echo "FAIL: aarch64 output is not an ELF file" >&2; exit 1
    fi
    [ "$(u16le "$PA" 18)" = 183 ] || { echo "FAIL: aarch64 output not EM_AARCH64" >&2; exit 1; }
    [ "$(u16le "$PA" 56)" = 2 ] || { echo "FAIL: aarch64 output not two PT_LOAD segments" >&2; exit 1; }
    echo "PASS: aarch64 LLVM-backend objects link with bnld (GOT relaxed; not run cross-arch)"
else
    echo "SKIP: LLVM-backend link not exercised (no clang) — native path verified"
fi
exit 0
