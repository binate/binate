#!/bin/sh
# e2e/stat-values.sh — Adversarially verify pkg/std/os's struct-stat decoding
# against the platform's real struct stat, using the system C compiler as the
# authoritative source.
#
# os.Stat reads the native struct stat by reproducing its layout field-for-field
# in Binate (impls/stdlib/pkg/std/os/sys/stat_<target>.bn) — a per-(os,arch) ABI
# fact that unit tests cannot pin (they run on no fixed layout). Instead we:
#   1. Compile + run a tiny C program that stat()s a known file and a known
#      directory and prints size / perm / type / mtime — the ground truth for
#      whatever (OS, arch) is compiling.
#   2. Compile + run a Binate program that os.Stat()s the SAME two paths and
#      prints the same facts through os.Stat's decoded FileInfo.
#   3. diff.  Any mismatch means Binate's struct-stat replica reads the wrong
#      bytes (a wrong field offset or width) on this target.
#
# The layout differs per (OS, arch), so the check is host-specific: run on
# x86_64 Linux it verifies that column, on arm64 macOS the Darwin column, etc.
# Under CI it runs on each e2e matrix host.
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
    *) echo "SKIP: stat-values unsupported on $(uname -s)"; exit 0 ;;
esac

CC="${CC:-$(command -v cc || command -v clang || command -v gcc || echo cc)}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/binate_e2e_stat.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A fixed file (known size via known content) and a fixed directory, created
# once and left untouched so their stat facts are stable across both runs.
STAT_FILE="$TMP/the_file"
STAT_DIR="$TMP/the_dir"
printf '0123456789' > "$STAT_FILE"   # 10 bytes
mkdir -p "$STAT_DIR"

# ---- 1. Ground truth: the real struct stat, via the system C compiler.
cat > "$TMP/cref.c" <<'EOF'
#include <sys/stat.h>
#include <stdio.h>
static void emit(const char *p) {
    struct stat st;
    if (stat(p, &st) != 0) { printf("-1\n"); return; }
    printf("%lld\n", (long long)st.st_size);
    printf("%d\n", (int)(st.st_mode & 0777));
    printf("%d\n", ((st.st_mode & S_IFMT) == S_IFREG) ? 1 : 0);
    printf("%d\n", ((st.st_mode & S_IFMT) == S_IFDIR) ? 1 : 0);
#ifdef __APPLE__
    printf("%lld\n", (long long)st.st_mtimespec.tv_sec);
    printf("%lld\n", (long long)st.st_mtimespec.tv_nsec);
#else
    printf("%lld\n", (long long)st.st_mtim.tv_sec);
    printf("%lld\n", (long long)st.st_mtim.tv_nsec);
#endif
}
int main(int argc, char **argv) { emit(argv[1]); emit(argv[2]); return 0; }
EOF
"$CC" -o "$TMP/cref" "$TMP/cref.c" || { echo "FAIL: C compile failed" >&2; exit 1; }
"$TMP/cref" "$STAT_FILE" "$STAT_DIR" > "$TMP/truth.txt"

# ---- 2. Binate's view: os.Stat the same two paths, print the same facts.
cat > "$TMP/sprobe.bn" <<EOF
package "main"

import "pkg/builtins/testing"
import "pkg/std/os"
import "pkg/std/errors"
import "pkg/std/time"

func yn(b bool) int {
	if b { return 1 }
	return 0
}

func emit(path *[]readonly char) {
	var fi @os.FileInfo
	var err @errors.Error
	fi, err = os.Stat(path)
	if present(err) {
		testing.Println(0 - 1)
		return
	}
	testing.Println(cast(int, fi.Size()))
	testing.Println(cast(int, fi.Mode().Perm()))
	testing.Println(yn(fi.Mode().IsRegular()))
	testing.Println(yn(fi.IsDir()))
	// Bind the time.Point to a var before calling ToUnix on it: chaining a
	// method onto the by-value struct result of a cross-package method
	// (fi.ModTime()) currently miscompiles (extractvalue on a scalar) — see
	// the "chained method on a cross-package struct-returning method" todo.
	var mt time.Point = fi.ModTime()
	var sec int64
	var nsec int32
	sec, nsec = mt.ToUnix()
	testing.Println(cast(int, sec))
	testing.Println(cast(int, nsec))
}

func main() {
	emit("$STAT_FILE")
	emit("$STAT_DIR")
}
EOF

# Compile the stat probe with a gen1 (checkout-source) compiler, resolving its
# stdlib deps from the checkout.  The probe prints via testing.Print*, which
# postdates the pinned BUILDER's frozen stdlib bundle — so the BUILDER cannot
# compile it directly.  resolve-gen1.sh builds+caches gen1 (the BUILDER compiling
# checkout cmd/bnc) once per tree state, so this stays cheap across the e2e run.
# Mirrors e2e/os-args.sh.
GEN1_BNC="$("$BINATE_DIR/scripts/resolve-gen1.sh")"
CK_I="$("$BINATE_DIR/scripts/binate-paths.sh" --iface --base "$BINATE_DIR")"
CK_L="$("$BINATE_DIR/scripts/binate-paths.sh" --impl --base "$BINATE_DIR")"
CK_RT="$BINATE_DIR/runtime/binate_runtime.c"
BNC_BIN="$TMP/sprobe"
BUILD_DIR="$TMP/build"
mkdir -p "$BUILD_DIR"
bnc_log=$("$GEN1_BNC" -I "$CK_I" -L "$CK_L" --runtime "$CK_RT" \
    --build-dir "$BUILD_DIR" -o "$BNC_BIN" "$TMP/sprobe.bn" 2>&1) || true
if [ ! -x "$BNC_BIN" ]; then
    echo "FAIL: Binate compile of the stat probe failed" >&2
    echo "$bnc_log" | sed 's/^/  /' >&2
    exit 1
fi
"$BNC_BIN" > "$TMP/binate.txt"

# ---- 3. Compare.
if ! diff "$TMP/truth.txt" "$TMP/binate.txt" > "$TMP/diff.txt"; then
    echo "FAIL: os.Stat values disagree with struct stat on $(uname -s) $(uname -m)" >&2
    echo "  (< real struct stat   > os.Stat)" >&2
    echo "  fields per path: size, perm, isreg, isdir, mtime_sec, mtime_nsec" >&2
    sed 's/^/  /' "$TMP/diff.txt" >&2
    exit 1
fi

echo "PASS: os.Stat matches struct stat on $(uname -s) $(uname -m) (file + dir)"
