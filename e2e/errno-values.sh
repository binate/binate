#!/bin/sh
# e2e/errno-values.sh — Adversarially verify pkg/std/os's errno→base value
# table against the platform's real <errno.h>, using the system C compiler as
# the authoritative source.
#
# Most errnos can't be triggered from os's surface, so unit tests can't pin
# their numeric values.  Instead we:
#   1. Compile + run a tiny C program that prints each errno's REAL value
#      (from <errno.h>) — the ground truth for whatever OS is compiling.
#   2. Extract the values pkg/std/os CLAIMS (impls/stdlib/common/pkg/std/os/
#      os_errno.bn) for that OS — os_errno.bn stays the single source, so this
#      cannot pass against a stale mirror.
#   3. diff.  Any mismatch fails the test.
#
# The numbers differ per OS (e.g. EAGAIN is 11 on Linux, 35 on Darwin), so the
# check is OS-specific: run on Linux it verifies the Linux column, on Darwin
# the Darwin column.  Under CI it runs on ubuntu (Linux column); the Darwin
# column is covered when run on a mac.
#
# Exit 0 on full agreement; non-zero with a diff on any mismatch.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(dirname "$SCRIPT_DIR")"
ERRNO_BN="$BINATE_DIR/impls/stdlib/common/pkg/std/os/os_errno.bn"

[ -f "$ERRNO_BN" ] || { echo "FAIL: not found: $ERRNO_BN" >&2; exit 1; }

case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    *)      echo "SKIP: errno-values unsupported on $(uname -s)"; exit 0 ;;
esac

CC="${CC:-$(command -v cc || command -v clang || command -v gcc || echo cc)}"
TMP="$(mktemp -d /tmp/binate_e2e_errno.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. Ground truth: the real <errno.h> value of each errno os classifies.
cat > "$TMP/dump.c" <<'EOF'
#include <errno.h>
#include <stdio.h>
#define DUMP(n) printf("%s %d\n", #n, n)
int main(void) {
    DUMP(EPERM);  DUMP(ENOENT); DUMP(EINTR); DUMP(EIO);   DUMP(ENXIO);
    DUMP(EBADF);  DUMP(ENOMEM); DUMP(EACCES);DUMP(EFAULT);DUMP(EBUSY);
    DUMP(EEXIST); DUMP(EXDEV);  DUMP(ENODEV);DUMP(ENOTDIR);DUMP(EISDIR);
    DUMP(EINVAL); DUMP(ENFILE); DUMP(EMFILE);DUMP(ETXTBSY);DUMP(EFBIG);
    DUMP(ENOSPC); DUMP(ESPIPE); DUMP(EROFS); DUMP(EMLINK);DUMP(EPIPE);
    DUMP(ERANGE);
    DUMP(EAGAIN); DUMP(ENAMETOOLONG); DUMP(ENOSYS); DUMP(ELOOP);
    DUMP(EOVERFLOW); DUMP(EOPNOTSUPP); DUMP(EDQUOT);
    return 0;
}
EOF
"$CC" -o "$TMP/dump" "$TMP/dump.c" || { echo "FAIL: C compile failed" >&2; exit 1; }
"$TMP/dump" | sort > "$TMP/truth.txt"

# ---- 2. os's claimed values for this OS, extracted from os_errno.bn.
# Shared codes (1..34) are an uppercase `NAME int = N` const block.  The 7
# codes that differ per OS are lowercase locals: `var name int = <linux>` with
# a `name = <darwin>` override inside `if build.OS == build.OS_DARWIN`.
awk -v os="$OS" '
    /^\t[A-Z][A-Z0-9_]* +int *= *[0-9]+/      { print $1, $4 + 0; next }
    /if build\.OS == build\.OS_DARWIN/         { dar = 1; next }
    dar && /^\t}/                              { dar = 0; next }
    /^\tvar [a-z][a-z0-9_]* int = [0-9]+/      { if (os == "linux")  print toupper($2), $5 + 0; next }
    dar && /^\t\t[a-z][a-z0-9_]* = [0-9]+/     { if (os == "darwin") print toupper($1), $3 + 0; next }
' "$ERRNO_BN" | sort > "$TMP/claimed.txt"

# Guard against silent under-extraction (e.g. os_errno.bn reformatted): the
# claimed set must cover exactly the errnos the dumper reports.
n_truth=$(wc -l < "$TMP/truth.txt")
n_claim=$(wc -l < "$TMP/claimed.txt")
if [ "$n_claim" -ne "$n_truth" ]; then
    echo "FAIL: extracted $n_claim claimed values but expected $n_truth" >&2
    echo "      (os_errno.bn format may have changed — fix the awk in $0)" >&2
    diff "$TMP/claimed.txt" "$TMP/truth.txt" >&2 || true
    exit 1
fi

# ---- 3. Compare.
if ! diff "$TMP/claimed.txt" "$TMP/truth.txt" > "$TMP/diff.txt"; then
    echo "FAIL: os_errno.bn errno values disagree with <errno.h> on $OS" >&2
    echo "  (< os_errno.bn claims   > real <errno.h>)" >&2
    sed 's/^/  /' "$TMP/diff.txt" >&2
    exit 1
fi

echo "PASS: all $n_truth errno values in os_errno.bn match <errno.h> on $OS"
