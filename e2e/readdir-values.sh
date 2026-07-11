#!/bin/sh
# e2e/readdir-values.sh — Adversarially verify pkg/std/os's ReadDir against the
# platform's real readdir(3), using the system C compiler as the authoritative
# source.
#
# os.ReadDir decodes the native struct dirent that readdir returns by
# reproducing the d_type / d_name offsets per (os, arch) in Binate
# (impls/stdlib/pkg/std/os/readdir_<target>.bn) — a per-(os,arch) ABI fact that
# unit tests cannot pin (they run on no fixed layout). Instead we:
#   1. Compile + run a tiny C program that readdir()s a known directory and, for
#      each known entry name, prints its d_type kind (reg/dir/lnk) — plus the
#      count of non-".",".." entries — the ground truth for this (OS, arch).
#   2. Compile + run a Binate program that os.ReadDir()s the SAME directory and
#      prints the same facts through os.ReadDir's decoded DirEntry list.
#   3. diff.  Any mismatch means Binate reads the wrong d_type/d_name bytes (a
#      wrong offset) on this target — or excludes the wrong entries.
#
# Finding an entry by name requires d_name to read correctly; reporting its kind
# requires d_type to read correctly; the count check pins ".",".." exclusion and
# dotfile inclusion.  The layout differs per (OS, arch), so the check is
# host-specific: it verifies whichever column the host is — x86_64 Linux or arm64
# macOS, the two 64-bit hosts the e2e CI matrix runs.  It does NOT cover the
# 32-bit-Linux (arm32) column (no 32-bit e2e host; the C reference here also uses
# plain readdir, which on a 32-bit host would itself differ from os.ReadDir's
# readdir64) — arm32 ReadDir is covered by the qemu conformance run (006_readdir).
#
# Exit 0 on full agreement; non-zero with a diff on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -d "$BINATE_DIR/pkg" ]; then
    echo "FAIL: BINATE_DIR not a binate repo: $BINATE_DIR" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) echo "SKIP: readdir-values unsupported on $(uname -s)"; exit 0 ;;
esac

CC="${CC:-$(command -v cc || command -v clang || command -v gcc || echo cc)}"
TMP="$(mktemp -d /tmp/binate_e2e_readdir.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A fixed directory holding one of each interesting kind, created once and left
# untouched so the listing is stable across both runs: a regular file, a
# subdirectory, a symlink (readdir reports the link itself, DT_LNK — it does not
# follow), and a dotfile (which ReadDir includes, unlike "." / "..").
READDIR_DIR="$TMP/the_dir"
mkdir -p "$READDIR_DIR"
printf 'x' > "$READDIR_DIR/afile"
mkdir -p "$READDIR_DIR/asubdir"
ln -s afile "$READDIR_DIR/alink"
printf 'y' > "$READDIR_DIR/.hidden"

# ---- 1. Ground truth: real readdir(3), via the system C compiler.
cat > "$TMP/cref.c" <<'EOF'
#include <dirent.h>
#include <string.h>
#include <stdio.h>
static int kind_of(unsigned char dt) {
    if (dt == DT_LNK) return 2;
    if (dt == DT_DIR) return 1;
    if (dt == DT_REG) return 0;
    return 9;  // DT_UNKNOWN or other; Binate's DirEntry agrees via ModeIrregular
}
int main(int argc, char **argv) {
    DIR *d = opendir(argv[1]);
    if (!d) { printf("-1\n"); return 0; }
    int count = 0, kf = -1, ks = -1, kl = -1, kh = -1;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        count++;
        if (strcmp(e->d_name, "afile") == 0) kf = kind_of(e->d_type);
        else if (strcmp(e->d_name, "asubdir") == 0) ks = kind_of(e->d_type);
        else if (strcmp(e->d_name, "alink") == 0) kl = kind_of(e->d_type);
        else if (strcmp(e->d_name, ".hidden") == 0) kh = kind_of(e->d_type);
    }
    closedir(d);
    printf("%d\n%d\n%d\n%d\n%d\n", count, kf, ks, kl, kh);
    return 0;
}
EOF
"$CC" -o "$TMP/cref" "$TMP/cref.c" || { echo "FAIL: C compile failed" >&2; exit 1; }
"$TMP/cref" "$READDIR_DIR" > "$TMP/truth.txt"

# ---- 2. Binate's view: os.ReadDir the same directory, print the same facts.
cat > "$TMP/rprobe.bn" <<EOF
package "main"

import "pkg/std/os"
import "pkg/std/errors"

func nameEq(a @[]readonly char, b *[]readonly char) bool {
	if len(a) != len(b) { return false }
	for i := 0; i < len(a); i++ {
		if a[i] != b[i] { return false }
	}
	return true
}

// kindOf maps a DirEntry to the same reg/dir/lnk codes the C reference uses.
func kindOf(e *readonly os.DirEntry) int {
	if (e.Type() & os.ModeSymlink) != cast(os.FileMode, 0) { return 2 }
	if e.IsDir() { return 1 }
	if e.Type() == cast(os.FileMode, 0) { return 0 }
	return 9
}

func main() {
	var ents @[]@os.DirEntry
	var err @errors.Error
	ents, err = os.ReadDir("$READDIR_DIR")
	if present(err) { println(0 - 1); return }
	var count int = 0
	var kf int = 0 - 1
	var ks int = 0 - 1
	var kl int = 0 - 1
	var kh int = 0 - 1
	for i := 0; i < len(ents); i++ {
		count = count + 1
		var nm @[]readonly char = ents[i].Name()
		if nameEq(nm, "afile") { kf = kindOf(ents[i]) }
		if nameEq(nm, "asubdir") { ks = kindOf(ents[i]) }
		if nameEq(nm, "alink") { kl = kindOf(ents[i]) }
		if nameEq(nm, ".hidden") { kh = kindOf(ents[i]) }
	}
	println(count)
	println(kf)
	println(ks)
	println(kl)
	println(kh)
}
EOF

# Compile the readdir probe by running cmd/bnc (current source) via the pinned
# BUILDER — no gen1 build needed.  os once required a .bni free-func/method fix
# (796effc7) that postdated the then-BUILDER (bnc-0.0.9); that fix is contained in
# the current BUILDER_VERSION, so the BUILDER compiles os directly.  Mirrors
# e2e/print-args.sh's BUILDER -> cmd/bnc form (inner -I/-L resolve os's stdlib
# deps from the BUILDER's frozen bundle, source prepended).
BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
BUILDER_LIB="$("$BINATE_DIR/scripts/fetch-builder.sh" --lib)"
BUILDER_RUNTIME="$("$BINATE_DIR/scripts/binate-paths.sh" --runtime --base "$BUILDER_LIB")"
BNC_BIN="$TMP/rprobe"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"
bnc_log=$("$BUILDER" \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")" \
    "$BINATE_DIR/cmd/bnc" -- \
    -I "$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    -L "$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BUILDER_LIB" --prepend "$BINATE_DIR")" \
    --runtime "$BUILDER_RUNTIME" \
    --build-dir "$BUILD_DIR" -o "$BNC_BIN" "$TMP/rprobe.bn" 2>&1) || true
if [ ! -x "$BNC_BIN" ]; then
    echo "FAIL: Binate compile of the readdir probe failed" >&2
    echo "$bnc_log" | sed 's/^/  /' >&2
    exit 1
fi
"$BNC_BIN" > "$TMP/binate.txt"

# ---- 3. Compare.
if ! diff "$TMP/truth.txt" "$TMP/binate.txt" > "$TMP/diff.txt"; then
    echo "FAIL: os.ReadDir disagrees with readdir(3) on $(uname -s) $(uname -m)" >&2
    echo "  (< real readdir   > os.ReadDir)" >&2
    echo "  fields: entry count, then kind of afile/asubdir/alink/.hidden (0=reg 1=dir 2=lnk)" >&2
    sed 's/^/  /' "$TMP/diff.txt" >&2
    exit 1
fi

echo "PASS: os.ReadDir matches readdir(3) on $(uname -s) $(uname -m) (file/dir/symlink/dotfile)"
