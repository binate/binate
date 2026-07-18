#!/bin/sh
# Usage: ./scripts/hygiene/file-format.sh
#
# Whitespace checks across authored text files, split by what bnfmt (the
# bnfmt-format check, canonical for .bn/.bni) does and does NOT enforce:
#
#   1. No trailing whitespace (spaces or tabs) at end of any line — checked on
#      .bn/.bni AND .sh/.md/.yml.  bnfmt normalizes trailing whitespace on CODE
#      lines but NOT inside comments (`// x   `, `/* ... */`), so this line-based
#      check is still needed for .bn/.bni to cover the comment case.
#   2. Every non-empty file ends with a final newline.
#   3. No trailing blank lines at end of file.
#      Checks 2-3 are .sh/.md/.yml ONLY: bnfmt already enforces both on every
#      .bn/.bni (verified), so re-checking them there would be redundant.
#
# Import-group ordering (.bn/.bni) is NOT checked here — it is entirely bnfmt's.
#
# Scope: .git/, conformance/ (intentional fixtures), and */testdata are excluded.
# Repo paths contain no spaces/tabs, so the newline list feeds `xargs awk` safely.
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

violations=0

ALL_LIST=$(mktemp -t hygiene-file-format-all.XXXXXX)
TEXT_LIST=$(mktemp -t hygiene-file-format-text.XXXXXX)
trap 'rm -f "$ALL_LIST" "$TEXT_LIST"' EXIT
find "$BINATE_DIR" \
    \( -path "$BINATE_DIR/.git" -o -path "$BINATE_DIR/conformance" -o -path '*/testdata' \) -prune \
    -o -type f \( -name '*.bn' -o -name '*.bni' -o -name '*.sh' \
                  -o -name '*.md' -o -name '*.yml' \) -print \
    | sort > "$ALL_LIST"
grep -E '\.(sh|md|yml)$' "$ALL_LIST" > "$TEXT_LIST" || true

# 1. Trailing whitespace — ALL files, one awk over the list (FNR = per-file line
#    number now that a single process spans every file).
out=$(xargs awk '
    /[ \t]+$/ {
        rel = FILENAME; sub(BINATE "/", "", rel)
        printf("%s:%d: trailing whitespace\n", rel, FNR)
    }
' BINATE="$BINATE_DIR" < "$ALL_LIST")
if [ -n "$out" ]; then
    echo "$out"
    violations=$((violations + $(printf '%s\n' "$out" | wc -l | tr -d ' ')))
fi

# 2. Final newline — .sh/.md/.yml only (bnfmt covers .bn/.bni).
while IFS= read -r f; do
    if [ -s "$f" ]; then
        # tail -c 1 → that one byte. wc -l counts newlines (0 or 1).
        if [ "$(tail -c 1 "$f" | wc -l | tr -d ' ')" -ne 1 ]; then
            rel=${f#"$BINATE_DIR"/}
            echo "$rel: missing final newline"
            violations=$((violations + 1))
        fi
    fi
done < "$TEXT_LIST"

# 3. No trailing blank lines — .sh/.md/.yml only (bnfmt covers .bn/.bni).  A
#    correctly-terminated file ends `<content>\n`; a trailing blank makes it
#    `<content>\n\n` — the last two bytes both newlines.
while IFS= read -r f; do
    if [ -s "$f" ]; then
        if [ "$(tail -c 2 "$f" | wc -l | tr -d ' ')" -eq 2 ]; then
            rel=${f#"$BINATE_DIR"/}
            echo "$rel: trailing blank line(s) at end of file"
            violations=$((violations + 1))
        fi
    fi
done < "$TEXT_LIST"

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "=== $violations file-format violation(s) ==="
    exit 1
fi
