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

# Build bootstrap once. bnlint's "main package" arg (cmd/bnlint) is resolved
# relative to cwd by the bootstrap (only -test mode resolves package paths via
# -root), so we have to run from BINATE_DIR. `go run` won't work from there
# because it looks for a Go module in cwd, so build the binary first.
BOOTSTRAP_BIN="$(mktemp -t binate-lint-bootstrap.XXXXXX)"
trap 'rm -f "$BOOTSTRAP_BIN"' EXIT
(cd "$BOOTSTRAP_DIR" && go build -o "$BOOTSTRAP_BIN" .) || exit 1

(cd "$BINATE_DIR" && "$BOOTSTRAP_BIN" -root "$BINATE_DIR" cmd/bnlint \
    -- --root "$BINATE_DIR" $TARGETS)
rc=$?

if [ "$rc" -ne 0 ]; then
    echo ""
    echo "=== lint failed (exit $rc) ==="
    exit 1
fi
