#!/bin/sh
# Usage: ./scripts/hygiene/conformance-imports.sh
#
# Verifies that conformance tests only import from a small whitelist of
# real packages, or from a test-local fixture inside the same test
# directory. Whitelisted real packages:
#
#   pkg/bootstrap   — system calls (Write, Exit, Args, file I/O)
#   pkg/builtins/rt          — runtime (refcount probes, alloc helpers)
#
# A file's "test directory" is the immediate child of conformance/ that
# contains it. Single-file tests (conformance/NNN_name.bn) have no test
# directory and may only use whitelisted imports. Multi-package tests
# (conformance/NNN_name/) may additionally import any "pkg/X" whose
# fixture exists at NNN_name/pkg/X/, NNN_name/pkg/X.bn, or
# NNN_name/pkg/X.bni.
#
# Per-import exemptions live in conformance-imports.whitelist
# (one `<conformance-relative-path>:<import-path>` per line). Use
# sparingly — e.g. for a negative test that deliberately imports a
# non-existent package.
#
# See section 9 of explorations/code-hygiene-check.md for the rationale.
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFORMANCE_DIR="$BINATE_DIR/conformance"
WHITELIST_FILE="$SCRIPT_DIR/conformance-imports.whitelist"

ALLOWED_REAL="pkg/bootstrap pkg/builtins/rt"

LIST=$(mktemp -t hygiene-conformance-imports-list.XXXXXX)
VIOLATIONS=$(mktemp -t hygiene-conformance-imports-out.XXXXXX)
trap 'rm -f "$LIST" "$VIOLATIONS"' EXIT

find "$CONFORMANCE_DIR" -type f \( -name '*.bn' -o -name '*.bni' \) \
    | sort > "$LIST"

is_exempt() {
    rel="$1"
    imp="$2"
    [ -f "$WHITELIST_FILE" ] || return 1
    grep -v '^[[:space:]]*#' "$WHITELIST_FILE" \
        | grep -v '^[[:space:]]*$' \
        | grep -Fxq "$rel:$imp"
}

while IFS= read -r f; do
    rel_conf="${f#$CONFORMANCE_DIR/}"
    rel_repo="${f#$BINATE_DIR/}"
    first="${rel_conf%%/*}"
    if [ "$first" = "$rel_conf" ]; then
        test_root=""
    else
        test_root="$CONFORMANCE_DIR/$first"
    fi

    # Extract every imported path of the form "pkg/...". Handles both
    # the single-line form `import "pkg/X"` and the grouped form
    # `import ( "pkg/X" "pkg/Y" )`. The state machine tolerates blank
    # lines and comments inside the group.
    imports=$(awk '
        /^import \(/ { in_group = 1; next }
        in_group && /^\)/ { in_group = 0; next }
        in_group {
            if (match($0, /"pkg\/[^"]+"/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
            }
            next
        }
        /^import "pkg\// {
            if (match($0, /"pkg\/[^"]+"/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
            }
        }
    ' "$f")

    [ -z "$imports" ] && continue

    printf '%s\n' "$imports" | while IFS= read -r imp; do
        [ -z "$imp" ] && continue

        # Whitelisted real package?
        for w in $ALLOWED_REAL; do
            if [ "$imp" = "$w" ]; then
                continue 2
            fi
        done

        # Test-local fixture?
        if [ -n "$test_root" ]; then
            local_path="$test_root/$imp"
            if [ -d "$local_path" ] || \
               [ -f "$local_path.bn" ] || \
               [ -f "$local_path.bni" ]; then
                continue
            fi
        fi

        # Per-file exemption?
        if is_exempt "$rel_conf" "$imp"; then
            continue
        fi

        echo "$rel_repo: disallowed import \"$imp\"" >> "$VIOLATIONS"
    done
done < "$LIST"

if [ -s "$VIOLATIONS" ]; then
    cat "$VIOLATIONS"
    n=$(wc -l < "$VIOLATIONS" | tr -d ' ')
    echo ""
    echo "=== $n conformance import violation(s) ==="
    echo "Allowed: $ALLOWED_REAL, plus any test-local fixture."
    echo "See $WHITELIST_FILE for per-file exemptions."
    exit 1
fi
