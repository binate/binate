#!/bin/sh
# Usage: ./scripts/hygiene/bni-doc.sh
#
# First-approximation check that every .bni file has the godoc comments
# documented in explorations/code-hygiene-check.md:
#   1. A package-level doc comment above the `package` declaration.
#   2. A doc comment above every top-level func, type, or const declaration
#      (or const group). Group members inside `const ( ... )` are not
#      individually checked.
#
# A "doc comment" is any `// ...` line. The doc carries through subsequent
# sibling declarations until interrupted by a non-decl, non-comment line
# (e.g. `import`, `package`). This matches the codebase convention where
# one doc comment heads a group of sibling funcs/types/consts.
#
# Intentional simplifications (first approximation):
# - Section banners like `// ============================` count as docs.
# - Doc presence is tracked by line shape, not content quality.
# - Indented lines inside a struct or const group are not inspected.
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

violations=0

for f in $(find "$BINATE_DIR/pkg" -name '*.bni' 2>/dev/null | sort); do
    out=$(awk '
        function flag(kind) {
            rel = FILENAME
            sub(BINATE "/", "", rel)
            printf("%s:%d: missing doc comment for %s: %s\n",
                   rel, NR, kind, $0)
            e++
        }
        # `doc_pending` is 1 when the current line falls under an active doc
        # comment (either directly or via a documented sibling chain).
        # Comments set it; recognized "neutral" continuations (blank lines,
        # struct-body or const-group lines, closing braces, sibling decls)
        # leave it alone; everything else (imports, etc.) resets it.

        # Doc comment line: opens or extends a doc block.
        /^[\t ]*\/\// { doc_pending = 1; next }

        # Blank line: neutral.
        NF == 0 { next }

        # Package declaration: must have a doc above. Resets state because
        # the package doc does not document subsequent decls.
        /^package "/ {
            if (!doc_pending) flag("package")
            doc_pending = 0
            next
        }

        # Top-level func / type / const declarations.
        /^func /  { if (!doc_pending) flag("func");  next }
        /^type /  { if (!doc_pending) flag("type");  next }
        /^const / { if (!doc_pending) flag("const"); next }

        # Indented lines, closing braces or close-paren of a const group:
        # neutral (we are inside a struct or a const group).
        /^[\t ]/  { next }
        /^[})]/   { next }

        # Anything else (imports, stray tokens) resets the doc pending flag.
        { doc_pending = 0 }

        END { exit e > 0 ? 1 : 0 }
    ' BINATE="$BINATE_DIR" "$f")
    if [ -n "$out" ]; then
        echo "$out"
        n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        violations=$((violations + n))
    fi
done

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "=== $violations .bni godoc violation(s) ==="
    exit 1
fi
