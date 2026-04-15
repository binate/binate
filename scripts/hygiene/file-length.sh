#!/bin/sh
# Usage: ./scripts/hygiene/file-length.sh
#
# Checks non-test .bn files for excessive length.
# Warns for files over 500 lines, errors for files over 600 lines.
# Test files (*_test.bn) are excluded — they may be longer.
#
# Exit code: 1 if any file exceeds 600 lines, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

WARN_LIMIT=500
ERROR_LIMIT=600

errors=0
warns=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" -name '*.bn' -not -name '*_test.bn' 2>/dev/null); do
    lines=$(wc -l < "$f")
    rel="${f#"$BINATE_DIR"/}"
    if [ "$lines" -gt "$ERROR_LIMIT" ]; then
        echo "ERROR: $rel: $lines lines (limit $ERROR_LIMIT)"
        errors=$((errors + 1))
    elif [ "$lines" -gt "$WARN_LIMIT" ]; then
        echo "WARN:  $rel: $lines lines (soft limit $WARN_LIMIT)"
        warns=$((warns + 1))
    fi
done

if [ "$errors" -gt 0 ] || [ "$warns" -gt 0 ]; then
    echo ""
    echo "=== $errors error(s), $warns warning(s) ==="
fi

if [ "$errors" -gt 0 ]; then
    exit 1
fi
