#!/bin/sh
# Usage: ./scripts/hygiene/stdx-forwarder-imports.sh
#
# A pkg/stdx/* compat forwarder (a .bni that is just `package "pkg/stdx/X"` +
# `expose "pkg/std/Y"`) names a package that was promoted to pkg/std; it is kept
# only TEMPORARILY, so existing importers still resolve while they migrate to the
# promoted home.  In-tree code must import the pkg/std/* home DIRECTLY, not the
# pkg/stdx/* forwarder; this check fails if any file imports a forwarder.
#
# Forwarders are auto-discovered (below), so the check re-arms automatically when a
# future promotion adds one and passes trivially when none exist.
#
# Exit code: 1 if any file imports a forwarder, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BINATE_DIR" || exit 2

FWD=$(mktemp -t hygiene-stdx-fwd.XXXXXX)
LIST=$(mktemp -t hygiene-stdx-list.XXXXXX)
IMPORTS=$(mktemp -t hygiene-stdx-imp.XXXXXX)
trap 'rm -f "$FWD" "$LIST" "$IMPORTS"' EXIT

# Auto-discover the forwarders: every pkg/stdx .bni re-exporting a pkg/std package.
# Emit "<stdx-path>\t<std-path>".  New forwarders are picked up automatically.
find ifaces/stdlib/pkg/stdx -name '*.bni' 2>/dev/null | while read -r f; do
    std=$(grep -m1 '^expose "pkg/std/' "$f" | sed -E 's/.*expose "([^"]*)".*/\1/')
    [ -z "$std" ] && continue
    stdx=$(grep -m1 '^package "' "$f" | sed -E 's/.*package "([^"]*)".*/\1/')
    [ -n "$stdx" ] && printf '%s\t%s\n' "$stdx" "$std"
done | sort -u > "$FWD"

if [ ! -s "$FWD" ]; then
    # No forwarders left — nothing to enforce (and the forwarders were removed, so
    # any lingering pkg/stdx import would be a plain unresolved-package build error).
    exit 0
fi

# Collect every in-tree Binate source file (a forwarder .bni has no import line, so
# it is naturally never a violation; testdata fixtures are excluded).
find cmd pkg ifaces impls conformance examples e2e \
    -type f \( -name '*.bn' -o -name '*.bni' \) -not -path '*/testdata/*' 2>/dev/null \
    | sort > "$LIST"

# Extract "<file>\t<import>" for every import, handling both the single-line
# `import "pkg/X"` and grouped `import ( "pkg/X" ... )` forms (mirrors
# conformance-imports.sh).  FNR==1 resets the group state per file.
if [ -s "$LIST" ]; then
    xargs awk '
        FNR == 1 { in_group = 0 }
        /^import \(/ { in_group = 1; next }
        in_group && /^\)/ { in_group = 0; next }
        in_group {
            if (match($0, /"pkg\/[^"]+"/)) print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /^import "pkg\// {
            if (match($0, /"pkg\/[^"]+"/)) print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
        }
    ' < "$LIST" > "$IMPORTS"
fi

# Reduce to just the forwarder imports in ONE awk pass (load FWD as a map, keep
# lines whose import is a forwarder) — emitting "<file>\t<stdx>\t<std>", so the
# per-line shell loop below stays tiny regardless of the tree's total import count.
CANDS=$(mktemp -t hygiene-stdx-cand.XXXXXX)
trap 'rm -f "$FWD" "$LIST" "$IMPORTS" "$CANDS"' EXIT
awk -F'\t' 'FNR==NR { fwd[$1] = $2; next } ($2 in fwd) { print $1 "\t" $2 "\t" fwd[$2] }' \
    "$FWD" "$IMPORTS" > "$CANDS"

violations=0
TAB=$(printf '\t')
while IFS="$TAB" read -r f imp std; do
    [ -z "$imp" ] && continue
    rel="${f#"$BINATE_DIR"/}"
    printf '%s: imports forwarder "%s" — use "%s"\n' "$rel" "$imp" "$std"
    violations=$((violations + 1))
done < "$CANDS"

if [ "$violations" -gt 0 ]; then
    echo "=== $violations forwarder-import violation(s) ==="
    echo "The pkg/stdx/* forwarders are temporary; import the pkg/std/* home directly."
    exit 1
fi
exit 0
