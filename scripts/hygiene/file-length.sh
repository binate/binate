#!/bin/sh
# Usage: ./scripts/hygiene/file-length.sh
#
# Checks non-test source files for excessive length.
#   .bn  (implementation): warns over 500 lines, errors over 600.
#   .bni (interface):      warns over 1500 lines, errors over 1800.  Interface
#        files aggregate a package's whole API and can't be split the way an
#        impl can, so they get a higher cap — but the cap still flags a
#        runaway interface (the fix there is splitting into sub-interfaces).
# Test files (*_test.bn) are excluded — they may be longer.
#
# TODO: consider lowering the .bni cap toward 1000/1200; ir.bni (~1159 lines)
# would need refactoring first.  See explorations/claude-todo.md.
#
# Exit code: 1 if any file exceeds its error limit, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BN_WARN_LIMIT=500
BN_ERROR_LIMIT=600
BNI_WARN_LIMIT=1500
BNI_ERROR_LIMIT=1800

errors=0
warns=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/ifaces" "$BINATE_DIR/impls" \( -name '*.bn' -o -name '*.bni' \) -not -name '*_test.bn' 2>/dev/null); do
    lines=$(wc -l < "$f")
    rel="${f#"$BINATE_DIR"/}"
    case "$f" in
        *.bni) warn=$BNI_WARN_LIMIT; err=$BNI_ERROR_LIMIT ;;
        *)     warn=$BN_WARN_LIMIT;  err=$BN_ERROR_LIMIT ;;
    esac
    if [ "$lines" -gt "$err" ]; then
        echo "ERROR: $rel: $lines lines (limit $err)"
        errors=$((errors + 1))
    elif [ "$lines" -gt "$warn" ]; then
        echo "WARN:  $rel: $lines lines (soft limit $warn)"
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
