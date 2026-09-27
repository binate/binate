#!/bin/sh
# Usage: ./scripts/hygiene/stdlib-forwarder-imports.sh
#
# A stdlib compat forwarder is a PURE FORWARDER package (see
# scripts/lib/stdlib-forwarders.sh: a .bni that is just `package "X"` +
# `expose "Y"`, with no implementation directory) left at a package's old path when
# the package moves to Y.  It is kept only TEMPORARILY, so existing importers still
# resolve while they migrate.  In-tree code must import the home Y DIRECTLY, not the
# forwarder X; this check fails if any file imports a forwarder.
#
# EXCEPTION — the BUILDER-compiled tree (scripts/lib/builder-tree.sh: cmd/bnc and the
# tree packages in its import closure).  gen1 compiles it with the pinned BUILDER
# against the BUILDER's OWN bundled stdlib, which only has the paths that existed when
# that BUILDER was cut.  Until a BUILDER whose bundle carries the new home is pinned,
# those packages must keep importing the old path (which the forwarder serves in
# every later, from-tree build).  A BUILDER-tree package is exempt as a whole,
# tests included, even though the BUILDER never compiles tests: that keeps one
# spelling of each moved package per package (a test importing the new home while the
# package's other files import the forwarder mixes the two spellings for no gain, since
# the package moves as a unit once the BUILDER is bumped).  The exempt set is computed
# from the actual import closure, so it cannot drift from the code; over-exempting is
# also backstopped by the forwarder's removal, which turns any lingering import into a
# build error.
#
# Forwarders are auto-discovered (below), so the check re-arms automatically whenever
# a stdlib package moves and passes trivially when none exist.
#
# Exit code: 1 if any non-exempt file imports a forwarder, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BINATE_DIR" || exit 2
. "$BINATE_DIR/scripts/lib/stdlib-forwarders.sh"
. "$BINATE_DIR/scripts/lib/builder-tree.sh"

FWD=$(mktemp -t hygiene-fwd.XXXXXX)
LIST=$(mktemp -t hygiene-fwd-list.XXXXXX)
IMPORTS=$(mktemp -t hygiene-fwd-imp.XXXXXX)
CANDS=$(mktemp -t hygiene-fwd-cand.XXXXXX)
BTREE=$(mktemp -t hygiene-fwd-btree.XXXXXX)
trap 'rm -f "$FWD" "$LIST" "$IMPORTS" "$CANDS" "$BTREE"' EXIT

# Auto-discover the forwarders: every pure-forwarder package in the stdlib iface
# tree.  Emit "<forwarder-path>\t<home-path>" (the first `expose` target names the
# home).  New forwarders are picked up automatically.
find ifaces/stdlib -name '*.bni' | sort | while read -r f; do
    pkg=${f#ifaces/stdlib/}
    pkg=${pkg%.bni}
    is_pure_forwarder "$BINATE_DIR" "$f" "$pkg" || continue
    home=$(grep -m1 '^expose "' "$f" | sed -E 's/.*expose "([^"]*)".*/\1/')
    printf '%s\t%s\n' "$pkg" "$home"
done > "$FWD"

if [ ! -s "$FWD" ]; then
    # No forwarders — nothing to enforce (and an import of a removed forwarder is a
    # plain unresolved-package build error).
    exit 0
fi

# Collect every in-tree Binate source file (a forwarder .bni has no import line, so
# it is naturally never a violation; testdata fixtures are excluded).  perf/ carries
# real .bn programs that import stdlib packages, so it must be scanned too — a perf
# benchmark importing a forwarder is as much a violation as any other in-tree file.
find cmd pkg ifaces impls conformance examples e2e perf \
    -type f \( -name '*.bn' -o -name '*.bni' \) -not -path '*/testdata/*' 2>/dev/null \
    | sort > "$LIST"

# Extract "<file>\t<import>" for every import, handling the single-line
# `import "pkg/X"`, aliased `import a "pkg/X"`, and grouped `import ( "pkg/X" ... )`
# forms (mirrors pkg-tiers.sh).  FNR==1 resets the group state per file.
if [ -s "$LIST" ]; then
    xargs awk '
        FNR == 1 { in_group = 0 }
        /^import[ \t]*\(/ { in_group = 1; next }
        in_group && /^\)/ { in_group = 0; next }
        in_group {
            if (match($0, /"pkg\/[^"]+"/)) print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        /^import[ \t]/ {
            if (match($0, /"pkg\/[^"]+"/)) print FILENAME "\t" substr($0, RSTART + 1, RLENGTH - 2)
        }
    ' < "$LIST" > "$IMPORTS"
fi

# Reduce to just the forwarder imports in ONE awk pass (load FWD as a map, keep
# lines whose import is a forwarder) — emitting "<file>\t<forwarder>\t<home>", so the
# per-line shell loop below stays tiny regardless of the tree's total import count.
awk -F'\t' 'FNR==NR { fwd[$1] = $2; next } ($2 in fwd) { print $1 "\t" $2 "\t" fwd[$2] }' \
    "$FWD" "$IMPORTS" > "$CANDS"
[ -s "$CANDS" ] || exit 0

# The BUILDER-tree exemption set (computed only when some file imports a forwarder).
builder_tree_packages "$BINATE_DIR" > "$BTREE"

# file_package <repo-relative-path>: the package a source file belongs to — its
# directory for a .bn, the path minus .bni (and minus a leading ifaces/<tree>/) for
# a .bni.
file_package() {
    case "$1" in
        *.bni)
            p=${1%.bni}
            case "$p" in ifaces/*/*) p=${p#ifaces/*/} ;; esac
            echo "$p"
            ;;
        *) dirname "$1" ;;
    esac
}

violations=0
TAB=$(printf '\t')
while IFS="$TAB" read -r f imp home; do
    [ -z "$imp" ] && continue
    rel="${f#"$BINATE_DIR"/}"
    if grep -qxF "$(file_package "$rel")" "$BTREE"; then
        continue
    fi
    printf '%s: imports forwarder "%s" — use "%s"\n' "$rel" "$imp" "$home"
    violations=$((violations + 1))
done < "$CANDS"

if [ "$violations" -gt 0 ]; then
    echo "=== $violations forwarder-import violation(s) ==="
    echo "Stdlib forwarders are temporary; import the forwarded-to home directly."
    echo "(The BUILDER-compiled tree is exempt — see the header of this script.)"
    exit 1
fi
exit 0
