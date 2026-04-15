#!/bin/sh
# Usage: ./scripts/hygiene/line-length.sh
#
# Checks .bn and .bni files for lines exceeding 100 characters.
# Test files are included in the check.
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LINE_LIMIT=100

count=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" \( -name '*.bn' -o -name '*.bni' \) 2>/dev/null); do
    rel="${f#"$BINATE_DIR"/}"
    awk -v limit="$LINE_LIMIT" -v file="$rel" \
        'length > limit { printf "%s:%d: %d chars\n", file, NR, length; found++ }
         END { exit (found > 0) }' "$f"
    if [ $? -ne 0 ]; then
        count=$((count + 1))
    fi
done

if [ "$count" -gt 0 ]; then
    echo ""
    echo "=== $count file(s) with lines over $LINE_LIMIT chars ==="
    exit 1
fi
