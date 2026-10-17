#!/bin/sh
# e2e/bnld-unwind-linux.sh — End-to-end proof that a program bnld links can be unwound
# through its C code on Linux: bnld writes the `.eh_frame_hdr` search table and its
# PT_GNU_EH_FRAME segment, by which glibc's unwinder (libgcc's _Unwind_Find_FDE, through
# dl_iterate_phdr) finds the executable's FDEs.
#
# A Binate program (`bnc --backend native --linker bnld`) calls unwind_depth(), in a C object
# clang compiles with its unwind tables (`.eh_frame`), linked in with --link-after-objs.  It
# goes three C frames deep and calls glibc's backtrace(), and the program exits with the number
# of frames backtrace() found.  With no table the unwinder finds no FDE for the program's own
# code and stops at the first frame (1); with it, it walks the four C frames (>= 4).
#
# Both linux-x64 and linux-aarch64 are built where the target's libc.so.6, which the link
# reads, is at hand (scripts/lib/linux-libc-sysroot.sh) and clang can cross-compile the C
# object; a target without them SKIPs.  The RUN needs the target's loader: x86-64 runs natively
# on an x86-64 Linux host, otherwise via Docker on a Linux CI lane or an explicit
# BINATE_E2E_DOCKER=1; aarch64 runs via Docker.  Exit 0 on pass (incl. run-skipped); non-zero
# on any failure.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: not a binate repo: $BINATE_DIR" >&2
    exit 1
fi
if ! command -v clang > /dev/null 2>&1; then
    echo "SKIP: bnld unwinding — needs clang to compile the C object"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnld_unwind.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

. "$BINATE_DIR/scripts/lib/linux-libc-sysroot.sh"
X64_SYSROOT="$(linux_libc_sysroot x86_64 "$TMP/sysroot_x64")" || X64_SYSROOT=""
AA64_SYSROOT="$(linux_libc_sysroot aarch64 "$TMP/sysroot_aa64")" || AA64_SYSROOT=""
_no_libc="needs its libc.so.6: a Linux host of that arch, or Docker (a Linux CI lane, or"
_no_libc="$_no_libc BINATE_E2E_DOCKER=1)"
if [ -z "$X64_SYSROOT" ] && [ -z "$AA64_SYSROOT" ]; then
    echo "SKIP: bnld unwinding — each Linux target $_no_libc"
    exit 0
fi

BNC="$TMP/bnc"
if ! "$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" > "$TMP/build_bnc.log" 2>&1; then
    echo "FAIL: could not build bnc" >&2
    cat "$TMP/build_bnc.log" >&2
    exit 1
fi

cat > "$TMP/unwind.bn" <<'BN'
package "main"

import "pkg/std/os"

func main() {
	os.Exit(cast(int, __c_call("unwind_depth", int64)))
}
BN

# Built at -O0, so each call is a frame of its own (no inlining, no tail calls).
cat > "$TMP/unwind.c" <<'C'
int backtrace(void **buffer, int size);

static long depth3(void) { void *frames[64]; return backtrace(frames, 64); }
static long depth2(void) { long n = depth3(); return n; }
static long depth1(void) { long n = depth2(); return n; }
long unwind_depth(void) { long n = depth1(); return n; }
C

# build <target-key> <clang-triple> <sysroot> -> sets $OUTBIN
build() {
    _key="$1"; _triple="$2"; _sysroot="$3"
    if ! clang -target "$_triple" -O0 -c "$TMP/unwind.c" -o "$TMP/unwind_$_key.o" \
            > "$TMP/cc_$_key.log" 2>&1; then
        echo "FAIL: clang could not compile the C object for $_key" >&2
        cat "$TMP/cc_$_key.log" >&2
        exit 1
    fi
    _out="$TMP/unwind_$_key"
    _iface="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR" --target "$_key")"
    _impl="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR" --target "$_key")"
    if ! "$BNC" --backend native --target "$_key" --linker bnld --sysroot "$_sysroot" \
            --link-after-objs "$TMP/unwind_$_key.o" -I "$_iface" -L "$_impl" \
            --build-dir "$TMP" -o "$_out" "$TMP/unwind.bn" > "$TMP/link_$_key.log" 2>&1; then
        echo "FAIL: bnc --linker bnld failed for $_key" >&2
        cat "$TMP/link_$_key.log" >&2
        exit 1
    fi
    OUTBIN="$_out"
}

X64BIN=""
AA64BIN=""
if [ -n "$X64_SYSROOT" ]; then
    build x86_64-linux x86_64-linux-gnu "$X64_SYSROOT"
    X64BIN="$OUTBIN"
else
    echo "SKIP: x86_64-linux $_no_libc"
fi
if [ -n "$AA64_SYSROOT" ]; then
    build aarch64-linux aarch64-linux-gnu "$AA64_SYSROOT"
    AA64BIN="$OUTBIN"
else
    echo "SKIP: aarch64-linux $_no_libc"
fi

DOCKER_OK=0
if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then DOCKER_OK=1; fi
if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then DOCKER_OK=1; fi
if [ "$DOCKER_OK" = 1 ]; then
    if ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then DOCKER_OK=0; fi
fi

# run_depth <bin> <docker-platform> <label>: the program's exit status is the frame count.
run_depth() {
    _bin="$1"; _plat="$2"; _label="$3"
    _ran=0; _code=0
    if [ "$_label" = x86_64-linux ] && [ "$(uname -s)" = Linux ] \
            && { [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = amd64 ]; }; then
        "$_bin"; _code=$?; _ran=1
    elif [ "$DOCKER_OK" = 1 ] \
            && docker run --rm --platform "$_plat" debian:stable-slim true > /dev/null 2>&1; then
        _dir="$(dirname "$_bin")"; _base="$(basename "$_bin")"
        _code="$(docker run --rm --platform "$_plat" -v "$_dir:/w" debian:stable-slim "/w/$_base" \
                > /dev/null 2>&1; echo $?)"
        case "$_code" in 125|127) _ran=0 ;; *) _ran=1 ;; esac
    fi
    if [ "$_ran" = 1 ]; then
        if [ "$_code" -lt 4 ] || [ "$_code" -gt 64 ]; then
            echo "FAIL: $_label backtrace() found $_code frames, not the four C frames or more" >&2
            exit 1
        fi
        echo "PASS: $_label — backtrace() unwound $_code frames through the bnld-linked C code"
    else
        echo "SKIP: $_label run (needs a native x86-64 Linux host or Docker) — build verified"
    fi
}

if [ -n "$X64BIN" ]; then run_depth "$X64BIN" linux/amd64 x86_64-linux; fi
if [ -n "$AA64BIN" ]; then run_depth "$AA64BIN" linux/arm64 aarch64-linux; fi

echo "ALL PASS: bnld unwinding (.eh_frame_hdr / PT_GNU_EH_FRAME)"
