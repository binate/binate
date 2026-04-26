#!/bin/sh
# Usage: ./scripts/hygiene/bn-doc.sh
#
# Checks the tightened godoc rule from explorations/code-hygiene-check.md §5:
# every top-level `func`, `type`, `const` (or `const ( ... )` group), and
# `var` declaration in a .bn file needs a `// ...` doc comment immediately
# above. No "trivial" carve-out.
#
# Heuristic notes:
# - "Doc above" means the closest non-blank line above the declaration is a
#   `// ...` line. A blank line between the comment and the declaration is
#   tolerated (common with section banners).
# - Unlike .bni, sibling decls do NOT inherit the previous decl's doc — each
#   `.bn` decl needs its own doc comment. The previous doc context is reset
#   after every decl.
# - `_test.bn` files are skipped: test helpers and Test* functions are
#   conventionally self-documenting by name.
#
# Limitations (intentional, first approximation):
# - Section banners and comment-shaped lines count as docs (shape, not content).
# - Group members inside `const ( ... )` are not individually inspected.
#
# TEMPORARY: pkg/asm/ and its subdirectories are still being documented.
# Their violations are reported as warnings (printed but not failing).
# Remove the warn-only branch below once pkg/asm is fully documented.
#
# Exit code: 1 if any non-warn violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

violations=0
warnings=0

for f in $(find "$BINATE_DIR/pkg" "$BINATE_DIR/cmd" -name '*.bn' \
                -not -name '*_test.bn' 2>/dev/null | sort); do
    out=$(awk '
        function flag(kind) {
            rel = FILENAME; sub(BINATE "/", "", rel)
            printf("%s:%d: missing doc comment for %s: %s\n",
                   rel, NR, kind, $0)
            e++
        }
        # Doc comment opens or extends a doc block.
        /^[\t ]*\/\// { doc_pending = 1; next }

        # Blank line: neutral.
        NF == 0 { next }

        # Top-level declarations: check, then reset doc_pending.
        # (.bn does not get the sibling-carry that .bni does.)
        # Note: package-level doc comments are not required in .bn; the
        # .bni carries the package doc, and main packages are entry
        # points whose role is obvious from context.
        /^package "/ { doc_pending = 0; next }
        /^func /     { if (!doc_pending) flag("func");    doc_pending = 0; next }
        /^type /     { if (!doc_pending) flag("type");    doc_pending = 0; next }
        /^const /    { if (!doc_pending) flag("const");   doc_pending = 0; next }
        /^var /      { if (!doc_pending) flag("var");     doc_pending = 0; next }

        # Indented lines (struct/const-group/func-body content) and closing
        # braces / parens at column 0: neutral.
        /^[\t ]/ { next }
        /^[})]/  { next }

        # Anything else (imports, stray tokens) resets the doc context.
        { doc_pending = 0 }

        END { exit e > 0 ? 1 : 0 }
    ' BINATE="$BINATE_DIR" "$f")
    [ -z "$out" ] && continue

    # TEMPORARY: pkg/asm/ violations report as warnings until that area
    # gets documented; everything else fails the script.
    case "$f" in
        "$BINATE_DIR"/pkg/asm/*)
            echo "$out" | sed 's/^/WARN: /'
            n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
            warnings=$((warnings + n))
            ;;
        *)
            echo "$out"
            n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
            violations=$((violations + n))
            ;;
    esac
done

if [ "$warnings" -gt 0 ] || [ "$violations" -gt 0 ]; then
    echo ""
    echo "=== $violations .bn godoc violation(s), $warnings warning(s) ==="
fi
[ "$violations" -gt 0 ] && exit 1
exit 0
