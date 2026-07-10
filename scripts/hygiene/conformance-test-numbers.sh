#!/bin/sh
# Usage: ./scripts/hygiene/conformance-test-numbers.sh
#
# Checks conformance/ for duplicate test numbers — i.e., a single NNN
# prefix that maps to more than one test (single-file *.bn, or
# multi-file NNN_*/ directory). Each test number must be unique.
#
# ALSO enforces discovery-completeness: every on-disk numbered test must be
# enumerable by the NNN-prefix globs.  The number NNN is any run of >=3 leading
# digits (4-digit numbers appear once the suite passes 999), so this guards
# against the enumeration globs silently narrowing back to exactly-3-digits —
# the defect that let 1001_xpkg_iface_assert run in zero modes.
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
# Exit code: 1 if any duplicates or undiscovered numbered tests found, 0 otherwise.

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
    for bn in "$emit_dir"/[0-9][0-9][0-9]*_*.bn; do
        [ -f "$bn" ] || continue
        name="$(basename "$bn" .bn)"
        if [ -f "$emit_dir/${name}.expected" ] || \
           [ -f "$emit_dir/${name}.error" ]; then
            num="${name%%_*}"
            printf "%s:%s %s\n" "$emit_ns" "$num" "$name"
        fi
    done
    for dir in "$emit_dir"/[0-9][0-9][0-9]*_*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        num="${name%%_*}"
        printf "%s:%s %s\n" "$emit_ns" "$num" "$name"
    done
}

# Scan every directory holding numbered tests, but PRUNE multi-file NNN_<name>/
# test directories so their internal files (package sources, a numbered .rules)
# are never mistaken for a namespace. The namespace is the directory's path
# relative to conformance/ (the top-level itself is "conformance").
{
    find "$CONFORMANCE_DIR" -type d -name '[0-9][0-9][0-9]*_*' -prune -o -type d -print |
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

# Discovery-completeness guard.  Independent of the enumeration globs above:
# walk every entry (via `*`, digit-agnostic) and classify "numbered test" by a
# >=3-leading-digit prefix — NOT by the `[0-9][0-9][0-9]*_` glob emit uses.  Any
# such stem that emit_test_numbers did not record (i.e. is absent from
# NUMS_TMP) means the enumeration glob is too narrow and dropped a real test.
MISS_TMP="$(mktemp "${TMPDIR:-/tmp}/conformance-missing.XXXXXX")"
find "$CONFORMANCE_DIR" -type d -name '[0-9][0-9][0-9]*_*' -prune -o -type d -print |
while IFS= read -r d; do
    if [ "$d" = "$CONFORMANCE_DIR" ]; then
        ns="conformance"
    else
        ns="${d#"$CONFORMANCE_DIR"/}"
    fi
    for e in "$d"/*; do
        [ -e "$e" ] || continue
        b="$(basename "$e")"
        # A numbered test starts with >=3 digits.  This classification does not
        # care where the underscore falls, so a 4-digit stem still qualifies.
        case "$b" in [0-9][0-9][0-9]*) ;; *) continue ;; esac
        if [ -d "$e" ]; then
            stem="$b"
        else
            stem="${b%%.*}"   # strip the sidecar suffix (.bn/.expected/.xfail...)
        fi
        case "$stem" in *_*) ;; *) continue ;; esac
        # Single-file stems count only with a .expected/.error sibling (mirrors
        # emit_test_numbers; skips package sources and other support files).
        if [ ! -d "$e" ]; then
            [ -f "$d/${stem}.expected" ] || [ -f "$d/${stem}.error" ] || continue
        fi
        if ! grep -qxF "${ns}:${stem%%_*} ${stem}" "$NUMS_TMP"; then
            printf "%s/%s\n" "$ns" "$stem" >> "$MISS_TMP"
        fi
    done
done
missing="$(sort -u "$MISS_TMP" | wc -l | tr -d ' ')"
if [ "$missing" -gt 0 ]; then
    echo "UNDISCOVERED (enumeration glob too narrow to see these numbered tests):"
    sort -u "$MISS_TMP" | sed 's/^/  /'
fi
rm -f "$NUMS_TMP" "$MISS_TMP"

if [ "$dups" -gt 0 ] || [ "$missing" -gt 0 ]; then
    echo ""
    [ "$dups" -gt 0 ] && echo "=== $dups duplicate test number(s) ==="
    [ "$missing" -gt 0 ] && echo "=== $missing undiscovered numbered test(s) ==="
    exit 1
fi
