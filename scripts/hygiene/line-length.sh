#!/bin/sh
# Usage: ./scripts/hygiene/line-length.sh
#
# Checks .bn and .bni files for lines exceeding 100 characters.
# Test files are included in the check.
#
# A line may opt out by ending with the marker "// LONG-LINE ALLOWED"
# (anywhere on the line). Use sparingly — only when splitting or
# shortening the line is impractical (e.g. a long error-message string
# literal).
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LINE_LIMIT=100

LIST=$(mktemp -t hygiene-line-length.XXXXXX)
trap 'rm -f "$LIST"' EXIT
find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/ifaces" "$BINATE_DIR/impls" \
    \( -name '*.bn' -o -name '*.bni' \) -not -path '*/testdata/*' 2>/dev/null \
    | sort > "$LIST"

# One awk over every file (FNR = per-file line number) — was one awk fork PER
# file (~thousands of forks).  A line opts out with the "// LONG-LINE ALLOWED"
# marker.  Violations are reported per offending line; the summary counts
# DISTINCT files (rel path is the pre-colon field, which file paths never
# contain), matching the original per-file tally.  Repo paths have no spaces,
# so the list feeds `xargs awk` safely.
out=""
if [ -s "$LIST" ]; then
    out=$(xargs awk -v limit="$LINE_LIMIT" '
        length > limit && index($0, "// LONG-LINE ALLOWED") == 0 {
            rel = FILENAME; sub(BINATE "/", "", rel)
            printf "%s:%d: %d chars\n", rel, FNR, length
        }
    ' BINATE="$BINATE_DIR" < "$LIST")
fi

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    count=$(printf '%s\n' "$out" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
    echo ""
    echo "=== $count file(s) with lines over $LINE_LIMIT chars ==="
    exit 1
fi
