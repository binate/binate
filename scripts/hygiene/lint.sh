#!/bin/sh
# Usage: ./scripts/hygiene/lint.sh
#
# Runs cmd/bnlint over every package under pkg/ and every command under cmd/.
# Fails if any lint diagnostic is reported.
#
# Exit code: 1 if any diagnostics found (or on bnlint error), 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_DIR="$(cd "$BINATE_DIR/../bootstrap" && pwd)"

# Discover targets:
#   - every directory under pkg/ that has any .bn files (excludes builtin
#     pkg/bootstrap, which has only the .bni interface)
#   - every directory under cmd/
TARGETS=""
for d in "$BINATE_DIR"/pkg/*/; do
    [ -d "$d" ] || continue
    # Skip dirs with no .bn files (defensive; pkg/bootstrap has no dir at all)
    found=0
    for bn in "$d"*.bn; do
        [ -f "$bn" ] && found=1 && break
    done
    [ "$found" -eq 1 ] || continue
    rel="pkg/$(basename "$d")"
    TARGETS="$TARGETS $rel"
done
for d in "$BINATE_DIR"/cmd/*/; do
    [ -d "$d" ] || continue
    rel="cmd/$(basename "$d")"
    TARGETS="$TARGETS $rel"
done

# Trim leading whitespace
TARGETS="$(echo "$TARGETS" | sed -e 's/^ *//')"

if [ -z "$TARGETS" ]; then
    echo "lint: no packages found"
    exit 1
fi

# Build bnlint via bnc (bnlint is no longer required to be bootstrap-runnable;
# see scripts/unittest/cmd-bnlint.xfail.boot and the bootstrap-surface scoping
# in CLAUDE.md).  No caching for now — each invocation rebuilds.
BNLINT_BIN="$(mktemp -t binate-lint.XXXXXX)"
trap 'rm -f "$BNLINT_BIN"' EXIT
"$SCRIPT_DIR/../build-bnlint.sh" -o "$BNLINT_BIN" >/dev/null || {
    echo "lint: failed to build bnlint" >&2
    exit 1
}

"$BNLINT_BIN" --root "$BINATE_DIR" $TARGETS
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
