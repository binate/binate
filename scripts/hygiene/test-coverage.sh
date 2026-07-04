#!/bin/sh
# Usage: ./scripts/hygiene/test-coverage.sh
#
# Checks that every non-test .bn file has a corresponding _test.bn file.
# Files listed in the whitelist (scripts/hygiene/test-coverage.whitelist)
# are excluded from the check.
#
# Exit code: 1 if any files are missing tests, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WHITELIST="$SCRIPT_DIR/test-coverage.whitelist"

missing=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/impls" -name '*.bn' -not -name '*_test.bn' -not -path '*/testdata/*' 2>/dev/null); do
    testf="${f%.bn}_test.bn"
    if [ -f "$testf" ]; then
        continue
    fi

    # A file with no function definitions (pure type / const ABI data — e.g. a
    # per-(os,arch) struct layout) has nothing to unit-test, so it needs neither
    # a _test.bn nor a whitelist entry.
    if ! grep -qE '^func ' "$f"; then
        continue
    fi

    rel="${f#"$BINATE_DIR"/}"

    # Check whitelist
    if [ -f "$WHITELIST" ]; then
        if grep -qxF "$rel" "$WHITELIST"; then
            continue
        fi
    fi

    echo "MISSING TEST: $rel"
    missing=$((missing + 1))
done

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "=== $missing file(s) missing test files ==="
    exit 1
fi
