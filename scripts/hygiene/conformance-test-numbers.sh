#!/bin/sh
# Usage: ./scripts/hygiene/conformance-test-numbers.sh
#
# Checks conformance/ for duplicate test numbers — i.e., a single NNN
# prefix that maps to more than one test (single-file *.bn, or
# multi-file NNN_*/ directory). Each test number must be unique.
#
# Exit code: 1 if any duplicates found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFORMANCE_DIR="$BINATE_DIR/conformance"

# A unique-per-run scratch file (mktemp, not a PID-based name) so concurrent
# hygiene runs in different worker sessions can't clobber each other's temp.
NUMS_TMP="$(mktemp "${TMPDIR:-/tmp}/conformance-numbers.XXXXXX")"

# Collect one entry per test:
#   single-file: NNN_<name>.bn (with a sibling .expected or .error)
#   multi-file:  NNN_<name>/ directory
# Print "<NNN> <test-name>" lines, one per test.
{
    for bn in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*.bn; do
        [ -f "$bn" ] || continue
        name="$(basename "$bn" .bn)"
        if [ -f "$CONFORMANCE_DIR/${name}.expected" ] || \
           [ -f "$CONFORMANCE_DIR/${name}.error" ]; then
            num="$(echo "$name" | cut -c1-3)"
            printf "%s %s\n" "$num" "$name"
        fi
    done
    for dir in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        num="$(echo "$name" | cut -c1-3)"
        printf "%s %s\n" "$num" "$name"
    done
} | sort > "$NUMS_TMP"

dups=0
prev_num=""
prev_name=""
group=""
while IFS=' ' read -r num name; do
    if [ "$num" = "$prev_num" ]; then
        if [ -z "$group" ]; then
            group="$prev_name $name"
        else
            group="$group $name"
        fi
    else
        if [ -n "$group" ]; then
            echo "DUPLICATE: $prev_num used by: $group"
            dups=$((dups + 1))
            group=""
        fi
        prev_num="$num"
        prev_name="$name"
    fi
done < "$NUMS_TMP"
if [ -n "$group" ]; then
    echo "DUPLICATE: $prev_num used by: $group"
    dups=$((dups + 1))
fi
rm -f "$NUMS_TMP"

if [ "$dups" -gt 0 ]; then
    echo ""
    echo "=== $dups duplicate test number(s) ==="
    exit 1
fi
