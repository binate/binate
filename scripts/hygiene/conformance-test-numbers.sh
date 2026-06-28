#!/bin/sh
# Usage: ./scripts/hygiene/conformance-test-numbers.sh
#
# Checks conformance/ for duplicate test numbers — i.e., a single NNN
# prefix that maps to more than one test (single-file *.bn, or
# multi-file NNN_*/ directory). Each test number must be unique.
#
# Numbering is per-directory: every directory that holds numbered tests is an
# independent namespace (the top-level conformance/ suite and each
# spec/<chapter>/ and stdlib/<chapter>/ restart at 001), so uniqueness is
# enforced WITHIN each directory, not across them. A 137 in spec/14-statements
# and a 137 in spec/07-types is fine; two 137s in one directory is not.
#
# The namespace set is DISCOVERED, not hard-coded: every directory that
# directly holds a numbered test is scanned, EXCEPT the internals of a
# multi-file NNN_<name>/ test (that is one test, not a namespace, so it is
# pruned). This tracks the same numbered subtrees the runner discovers and
# covers any future one automatically (avoiding a hand-maintained whitelist).
#
# Exit code: 1 if any duplicates found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFORMANCE_DIR="$BINATE_DIR/conformance"

# A unique-per-run scratch file (mktemp, not a PID-based name) so concurrent
# hygiene runs in different worker sessions can't clobber each other's temp.
NUMS_TMP="$(mktemp "${TMPDIR:-/tmp}/conformance-numbers.XXXXXX")"

# Emit "<namespace>:<NNN> <test-name>" for every test directly in $1.
#   $1 = directory to scan; $2 = namespace label (space-free) for the key.
# Collects both single-file tests (NNN_<name>.bn with a sibling .expected
# or .error) and multi-file tests (NNN_<name>/ directory). The namespace is
# part of the key so duplicate detection is per-directory.
emit_test_numbers() {
    emit_dir="$1"
    emit_ns="$2"
    for bn in "$emit_dir"/[0-9][0-9][0-9]_*.bn; do
        [ -f "$bn" ] || continue
        name="$(basename "$bn" .bn)"
        if [ -f "$emit_dir/${name}.expected" ] || \
           [ -f "$emit_dir/${name}.error" ]; then
            num="$(echo "$name" | cut -c1-3)"
            printf "%s:%s %s\n" "$emit_ns" "$num" "$name"
        fi
    done
    for dir in "$emit_dir"/[0-9][0-9][0-9]_*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        num="$(echo "$name" | cut -c1-3)"
        printf "%s:%s %s\n" "$emit_ns" "$num" "$name"
    done
}

# Scan every directory holding numbered tests, but PRUNE multi-file NNN_<name>/
# test directories so their internal files (package sources, a numbered .rules)
# are never mistaken for a namespace. The namespace is the directory's path
# relative to conformance/ (the top-level itself is "conformance").
{
    find "$CONFORMANCE_DIR" -type d -name '[0-9][0-9][0-9]_*' -prune -o -type d -print |
    while IFS= read -r d; do
        if [ "$d" = "$CONFORMANCE_DIR" ]; then
            ns="conformance"
        else
            ns="${d#"$CONFORMANCE_DIR"/}"
        fi
        emit_test_numbers "$d" "$ns"
    done
} | sort > "$NUMS_TMP"

dups=0
prev_key=""
prev_name=""
group=""
while IFS=' ' read -r key name; do
    if [ "$key" = "$prev_key" ]; then
        if [ -z "$group" ]; then
            group="$prev_name $name"
        else
            group="$group $name"
        fi
    else
        if [ -n "$group" ]; then
            echo "DUPLICATE: $prev_key used by: $group"
            dups=$((dups + 1))
            group=""
        fi
        prev_key="$key"
        prev_name="$name"
    fi
done < "$NUMS_TMP"
if [ -n "$group" ]; then
    echo "DUPLICATE: $prev_key used by: $group"
    dups=$((dups + 1))
fi
rm -f "$NUMS_TMP"

if [ "$dups" -gt 0 ]; then
    echo ""
    echo "=== $dups duplicate test number(s) ==="
    exit 1
fi
