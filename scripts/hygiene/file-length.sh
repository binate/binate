#!/bin/sh
# Usage: ./scripts/hygiene/file-length.sh
#
# Checks non-test source files for excessive length.
#   .bn  (implementation): 500 lines.
#   .bni (interface):      1000 lines.  A package's whole API lives in one
#        interface file — the loader loads a single <pkg>.bni, so unlike an
#        impl's .bn files a .bni cannot be split within its package.  A .bni over
#        the cap means the package's public interface is too big: decompose the
#        package (peel a cohesive concern into an acyclic sub-package, as with
#        ir->{irbuild,iropt}, vm->vmopcode, types->check) rather than growing it.
# Test files (*_test.bn) are excluded — they may be longer.
#
# There is no warn/grace band: a file over its limit fails immediately, on the
# first offender.  The limit is a forcing function against single-file blobs —
# when a file crosses it, split it along natural boundaries rather than letting
# it grow (see "Take Warnings Seriously" in CLAUDE.md).
#
# Exit code: 1 if ANY file exceeds its limit; 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BN_LIMIT=500
BNI_LIMIT=1000

errors=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" "$BINATE_DIR/ifaces" "$BINATE_DIR/impls" \( -name '*.bn' -o -name '*.bni' \) -not -name '*_test.bn' -not -path '*/testdata/*' 2>/dev/null); do
    lines=$(wc -l < "$f")
    rel="${f#"$BINATE_DIR"/}"
    case "$f" in
        *.bni) limit=$BNI_LIMIT ;;
        *)     limit=$BN_LIMIT ;;
    esac
    if [ "$lines" -gt "$limit" ]; then
        echo "ERROR: $rel: $lines lines (limit $limit)"
        errors=$((errors + 1))
    fi
done

if [ "$errors" -gt 0 ]; then
    echo ""
    echo "=== $errors file(s) over the length limit ==="
    exit 1
fi
