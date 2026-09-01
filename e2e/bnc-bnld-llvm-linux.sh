#!/bin/sh
# e2e/bnc-bnld-llvm-linux.sh — End-to-end proof that bnc links a REAL program with the
# self-hosted linker (bnld, via `--linker bnld`) instead of ld, using the DEFAULT LLVM
# backend (not --backend native), on Linux.
#
# The sibling bnc-bnld-linux.sh proves this for the native backend; this one proves bnld
# also consumes the objects the LLVM backend (clang) emits — the compiler's default path.
# `bnc --linker bnld --target <arch>` compiles via LLVM to an object and links it with the
# in-process pkg/binate/link (no ld): bnc's embedded `_start` calls libc's
# __libc_start_main, and the program is dynamically linked against libc.so.6.  So the LINK
# runs with no C linker/driver (clang still COMPILES here — that IS the LLVM backend — but
# ld is never invoked; contrast the native backend, which drops clang from compile too).
#
# The program allocates a managed slice, fills and sums it (make_slice -> malloc, bounds
# checks, refcount), and exits 42 via os.Exit (libc exit).  Both linux-x64 and
# linux-aarch64 are built + structure-checked (host-independent: clang cross-emits the ELF
# object, bnld links it).  The RUN needs the target's loader: x86-64 runs natively on an
# x86-64 Linux host, else via Docker on a Linux CI lane or an explicit BINATE_E2E_DOCKER=1;
# aarch64 runs via Docker.  Exit 0 on pass (incl. run-skipped); non-zero on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnc_bnld_llvm.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ----- build bnc from the current tree (it embeds bnld via pkg/binate/link) -----
BNC="$TMP/bnc"
if ! "$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" > "$TMP/build_bnc.log" 2>&1; then
    echo "FAIL: could not build bnc" >&2
    cat "$TMP/build_bnc.log" >&2
    exit 1
fi

# ----- the program: exit 42 via a heap-slice sum + libc os.Exit -----
cat > "$TMP/tiny.bn" <<'BN'
package "main"

import "pkg/std/os"

func compute() int {
	var xs @[]int = make_slice(int, 5)
	for i := 0; i < 5; i++ { xs[i] = i + 1 }
	var s int = 0
	for i := 0; i < len(xs); i++ { s = s + xs[i] }
	return s // 15
}

func main() {
	os.Exit(compute() + 27) // 42 — via libc exit()
}
BN

# build_and_check <target-key> <expect-interp> -> sets $OUTBIN
build_and_check() {
    _key="$1"; _interp="$2"
    _out="$TMP/tiny_$_key"
    _iface="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target "$_key")"
    _impl="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
    # No --backend native: this is the DEFAULT (LLVM) backend + the bnld linker.
    if ! "$BNC" --target "$_key" --linker bnld -I "$_iface" -L "$_impl" \
            --build-dir "$TMP" -o "$_out" "$TMP/tiny.bn" > "$TMP/link_$_key.log" 2>&1; then
        echo "FAIL: bnc (LLVM backend) --linker bnld failed for $_key" >&2
        cat "$TMP/link_$_key.log" >&2
        exit 1
    fi
    _magic="$(od -An -tx1 -N4 "$_out" | tr -d ' \n')"
    if [ "$_magic" != "7f454c46" ]; then
        echo "FAIL: $_key output is not an ELF file (magic $_magic)" >&2
        exit 1
    fi
    if ! grep -q "$_interp" "$_out"; then
        echo "FAIL: $_key output has no PT_INTERP ($_interp)" >&2
        exit 1
    fi
    if ! grep -q "libc.so.6" "$_out"; then
        echo "FAIL: $_key output does not name libc.so.6 (DT_NEEDED)" >&2
        exit 1
    fi
    OUTBIN="$_out"
    echo "PASS: $_key — bnc (LLVM backend) --linker bnld produced a dynamic ELF (interp + libc.so.6), no ld"
}

build_and_check x86_64-linux "/lib64/ld-linux-x86-64.so.2"
X64BIN="$OUTBIN"
build_and_check aarch64-linux "/lib/ld-linux-aarch64.so.1"
AA64BIN="$OUTBIN"

# ----- run gating: native x86-64 Linux, else Docker (CI Linux or BINATE_E2E_DOCKER) -----
DOCKER_OK=0
if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then DOCKER_OK=1; fi
if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then DOCKER_OK=1; fi
if [ "$DOCKER_OK" = 1 ]; then
    if ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then DOCKER_OK=0; fi
fi

# run_expect <bin> <docker-platform> <label>
run_expect() {
    _bin="$1"; _plat="$2"; _label="$3"
    _ran=0; _code=0
    if [ "$_label" = x86_64-linux ] && [ "$(uname -s)" = Linux ] \
            && { [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = amd64 ]; }; then
        "$_bin"; _code=$?; _ran=1
    elif [ "$DOCKER_OK" = 1 ] \
            && docker run --rm --platform "$_plat" debian:stable-slim true > /dev/null 2>&1; then
        _dir="$(dirname "$_bin")"; _base="$(basename "$_bin")"
        _code="$(docker run --rm --platform "$_plat" -v "$_dir:/w" debian:stable-slim "/w/$_base" > /dev/null 2>&1; echo $?)"
        case "$_code" in 125|127) _ran=0 ;; *) _ran=1 ;; esac
    fi
    if [ "$_ran" = 1 ]; then
        if [ "$_code" != 42 ]; then
            echo "FAIL: $_label program expected exit 42, got $_code" >&2
            exit 1
        fi
        echo "PASS: $_label — the bnc (LLVM) --linker bnld program ran and exited 42 (heap sum + libc exit)"
    else
        echo "SKIP: $_label run (needs a native x86-64 Linux host or Docker) — build+structure verified"
    fi
}

run_expect "$X64BIN" linux/amd64 x86_64-linux
run_expect "$AA64BIN" linux/arm64 aarch64-linux

echo "ALL PASS: bnc (LLVM backend) --linker bnld (self-hosted final link, no ld)"
