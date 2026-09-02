#!/bin/sh
# e2e/bnc-bnld-macos.sh — End-to-end proof that `bnc --linker bnld` produces a working
# dynamically-linked arm64 Mach-O on macOS, for BOTH backends: --backend native (no clang
# at all) and the default LLVM backend (clang COMPILES to an object, but bnld — not ld —
# LINKs it).  Either way the embedded self-hosted linker (bnld, via pkg/binate/link) links
# the objects against libSystem and ad-hoc code-signs the result; dyld's LC_MAIN runs the
# program's own C `main` (the #[c_export("main")] Binate entry) after libSystem init — no
# crt1, no synthetic _start.  The absolute in-image pointers (vtables, type info,
# descriptor nodes) are rebased by dyld via the LC_DYLD_INFO rebase stream, so the
# mandatory-PIE image runs correctly under ASLR.  (The LLVM object's __compact_unwind — the
# one section bearing section-relative relocs — is dropped by bnld, as ld64 consumes it.)
#
# bnc has no macos-arm64 --target KEY yet: a macOS Mach-O comes only from a HOST build on
# Apple Silicon.  So — unlike bnld-macho-dynamic.sh, which cross-targets host-independent
# Mach-O bytes via bnas/bnld -target macos-arm64 — this whole flow is macOS-arm64-only and
# SKIPs on any other host.
set -eu

BINATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "SKIP: bnc --linker bnld macOS e2e needs a macOS arm64 host (bnc has no macos-arm64 --target key)"
    exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_bnc_bnld_macos.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ----- build bnc from the current tree (it embeds bnld via pkg/binate/link) -----
BNC="$TMP/bnc"
if ! "$BINATE_DIR/scripts/build-bnc.sh" -o "$BNC" > "$TMP/build_bnc.log" 2>&1; then
    echo "FAIL: could not build bnc" >&2
    cat "$TMP/build_bnc.log" >&2
    exit 1
fi

# ----- the program: exit 42 via a heap-slice sum + libSystem exit -----
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
	os.Exit(compute() + 27) // 42 — via libSystem exit()
}
BN

# The host build on Apple Silicon implicitly targets macos-arm64 (native arch + Mach-O
# object format); there is no separate --target key, so omit it.
IFACE="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
IMPL="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
# build_run <backend-args> <label>: compile tiny.bn with `--linker bnld` (+ backend args),
# check the Mach-O structure + rebase stream, then run it (dyld + ASLR) expecting exit 42.
build_run() {
    _bargs="$1"; _label="$2"
    _out="$TMP/tiny_$_label"
    # shellcheck disable=SC2086 # _bargs is an intentional flag list, possibly empty
    if ! "$BNC" $_bargs --linker bnld -I "$IFACE" -L "$IMPL" \
            --build-dir "$TMP" -o "$_out" "$TMP/tiny.bn" > "$TMP/link_$_label.log" 2>&1; then
        echo "FAIL: bnc ($_label) --linker bnld failed" >&2
        cat "$TMP/link_$_label.log" >&2
        exit 1
    fi
    # Structure: an arm64 Mach-O (MH_MAGIC_64, cffaedfe little-endian) that links libSystem.
    _magic="$(od -An -tx1 -N4 "$_out" | tr -d ' \n')"
    if [ "$_magic" != "cffaedfe" ]; then
        echo "FAIL: $_label output is not an arm64 Mach-O (magic $_magic)" >&2
        exit 1
    fi
    if ! grep -q "libSystem" "$_out"; then
        echo "FAIL: $_label output does not link libSystem (LC_LOAD_DYLIB)" >&2
        exit 1
    fi
    # A real program has absolute pointers, so the linker must have emitted a rebase stream
    # (LC_DYLD_INFO rebase_size > 0); otherwise the PIE image would fault under ASLR.
    _rsize="$(otool -l "$_out" 2>/dev/null | grep -A5 LC_DYLD_INFO | awk '/rebase_size/ {print $2; exit}')"
    if [ "${_rsize:-0}" -le 0 ]; then
        echo "FAIL: $_label output has an empty rebase stream (rebase_size=${_rsize:-none})" >&2
        exit 1
    fi
    echo "PASS: $_label — dynamic arm64 Mach-O (libSystem, ad-hoc signed, rebase stream), no ld"
    # The program exits 42 (non-zero), so guard the call from `set -e` and capture its code.
    _code=0
    "$_out" || _code=$?
    if [ "$_code" != 42 ]; then
        echo "FAIL: $_label program expected exit 42, got $_code" >&2
        exit 1
    fi
    echo "PASS: $_label — ran under dyld+ASLR and exited 42 (rebase applied)"
}

# native: no clang at all.  llvm (default backend): clang COMPILES the object (bnld drops
# its __compact_unwind), but bnld — not ld — LINKs it.
# Use the explicit `--target aarch64-darwin` key (on this Apple-Silicon host it matches the
# implicit host target, and it is the same key that cross-builds a macOS Mach-O from Linux).
build_run "--backend native --target aarch64-darwin" native
build_run "--target aarch64-darwin" llvm

echo "ALL PASS: bnc --linker bnld on macOS, native + LLVM backends (self-hosted final link, no ld)"
