#!/bin/sh
# e2e/bnc-bnld-macos.sh — End-to-end proof that `bnc --linker bnld` produces a working
# dynamically-linked arm64 Mach-O on macOS, with no clang/ld.  bnc compiles a Binate
# program with --backend native and its embedded self-hosted linker (bnld, via
# pkg/binate/link) links the objects against libSystem and ad-hoc code-signs the result.
# dyld's LC_MAIN runs the program's own C `main` (the #[c_export("main")] Binate entry)
# after libSystem init — no crt1, no synthetic _start.  The absolute in-image pointers
# (vtables, type info, descriptor nodes) are rebased by dyld via the LC_DYLD_INFO rebase
# stream, so the mandatory-PIE image runs correctly under ASLR.
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
OUT="$TMP/tiny"
if ! "$BNC" --backend native --linker bnld -I "$IFACE" -L "$IMPL" \
        --build-dir "$TMP" -o "$OUT" "$TMP/tiny.bn" > "$TMP/link.log" 2>&1; then
    echo "FAIL: bnc --linker bnld failed" >&2
    cat "$TMP/link.log" >&2
    exit 1
fi

# Structure: an arm64 Mach-O (MH_MAGIC_64, cffaedfe little-endian) that links libSystem.
_magic="$(od -An -tx1 -N4 "$OUT" | tr -d ' \n')"
if [ "$_magic" != "cffaedfe" ]; then
    echo "FAIL: output is not an arm64 Mach-O (magic $_magic)" >&2
    exit 1
fi
if ! grep -q "libSystem" "$OUT"; then
    echo "FAIL: output does not link libSystem (DT_LOAD_DYLIB)" >&2
    exit 1
fi
# A real program has absolute pointers, so the linker must have emitted a rebase stream
# (LC_DYLD_INFO rebase_size > 0); otherwise the PIE image would fault under ASLR.
if ! otool -l "$OUT" 2>/dev/null | grep -A5 LC_DYLD_INFO | grep -q 'rebase_size'; then
    echo "FAIL: output has no LC_DYLD_INFO (no dyld fixups)" >&2
    exit 1
fi
_rsize="$(otool -l "$OUT" 2>/dev/null | grep -A5 LC_DYLD_INFO | awk '/rebase_size/ {print $2; exit}')"
if [ "${_rsize:-0}" -le 0 ]; then
    echo "FAIL: output has an empty rebase stream (rebase_size=$_rsize) — absolute pointers would dangle" >&2
    exit 1
fi
echo "PASS: bnc --linker bnld produced a dynamic arm64 Mach-O (libSystem, ad-hoc signed, rebase stream), no clang/ld"

# ----- run: natively (dyld + ASLR); the kernel mandates PIE + a valid signature. -----
# The program exits 42 (non-zero), so guard the call from `set -e` and capture its code.
_code=0
"$OUT" || _code=$?
if [ "$_code" != 42 ]; then
    echo "FAIL: program expected exit 42, got $_code" >&2
    exit 1
fi
echo "PASS: the bnc --linker bnld program ran under dyld+ASLR and exited 42 (rebase applied)"

echo "ALL PASS: bnc --linker bnld on macOS (self-hosted final link, no clang/ld)"
