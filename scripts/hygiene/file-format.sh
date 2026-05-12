#!/bin/sh
# Usage: ./scripts/hygiene/file-format.sh
#
# Four checks across authored text files in the repo:
#   1. No trailing whitespace (spaces or tabs) at end of any line.
#   2. Every non-empty file ends with a final newline.
#   3. No trailing blank lines — the last byte before the file's
#      final newline must not itself be a newline.
#   4. (.bn / .bni only) Each contiguous run of `import "..."` lines is
#      sorted alphabetically. A blank line or any non-import line ends
#      the current group; the next run is a fresh group.
#
# Scope: .bn, .bni, .sh, .md, .yml under the binate repo root, excluding
# .git/ and conformance/ (test fixtures with intentional formats).
#
# Exit code: 1 if any violations found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

violations=0

# Build file list (NUL-separated → tmp file to handle filenames safely
# without going through shell word-splitting).
LIST=$(mktemp -t hygiene-file-format.XXXXXX)
trap 'rm -f "$LIST"' EXIT
find "$BINATE_DIR" \
    \( -path "$BINATE_DIR/.git" -o -path "$BINATE_DIR/conformance" \) -prune \
    -o -type f \( -name '*.bn' -o -name '*.bni' -o -name '*.sh' \
                  -o -name '*.md' -o -name '*.yml' \) -print \
    | sort > "$LIST"

# 1. Trailing whitespace
while IFS= read -r f; do
    out=$(awk '
        /[ \t]+$/ {
            rel = FILENAME; sub(BINATE "/", "", rel)
            printf("%s:%d: trailing whitespace\n", rel, NR)
            e++
        }
        END { exit e > 0 ? 1 : 0 }
    ' BINATE="$BINATE_DIR" "$f")
    if [ -n "$out" ]; then
        echo "$out"
        n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        violations=$((violations + n))
    fi
done < "$LIST"

# 2. Final newline
while IFS= read -r f; do
    if [ -s "$f" ]; then
        # tail -c 1 → that one byte. wc -l counts newlines (0 or 1).
        if [ "$(tail -c 1 "$f" | wc -l | tr -d ' ')" -ne 1 ]; then
            rel=${f#"$BINATE_DIR"/}
            echo "$rel: missing final newline"
            violations=$((violations + 1))
        fi
    fi
done < "$LIST"

# 3. No trailing blank lines.  A correctly-terminated file ends with
#    `<content>\n`; one trailing blank line makes it `<content>\n\n`.
#    Detect by checking whether the last two bytes are both newlines.
while IFS= read -r f; do
    if [ -s "$f" ]; then
        if [ "$(tail -c 2 "$f" | wc -l | tr -d ' ')" -eq 2 ]; then
            rel=${f#"$BINATE_DIR"/}
            echo "$rel: trailing blank line(s) at end of file"
            violations=$((violations + 1))
        fi
    fi
done < "$LIST"

# 4. Import group ordering (.bn, .bni only)
while IFS= read -r f; do
    case "$f" in
        *.bn|*.bni) ;;
        *) continue ;;
    esac
    out=$(awk '
        function check_group(   i, sorted) {
            if (idx <= 1) { idx = 0; return }
            sorted = 1
            for (i = 2; i <= idx; i++) {
                if (paths[i-1] > paths[i]) { sorted = 0; break }
            }
            if (!sorted) {
                rel = FILENAME; sub(BINATE "/", "", rel)
                printf("%s:%d: import group not alphabetical\n",
                       rel, group_start)
                e++
            }
            idx = 0
        }
        /^import "/ {
            if (idx == 0) group_start = NR
            idx++
            paths[idx] = $0
            in_grp = 1
            next
        }
        in_grp { check_group(); in_grp = 0 }
        END {
            if (in_grp) check_group()
            exit e > 0 ? 1 : 0
        }
    ' BINATE="$BINATE_DIR" "$f")
    if [ -n "$out" ]; then
        echo "$out"
        n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        violations=$((violations + n))
    fi
done < "$LIST"

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "=== $violations file-format violation(s) ==="
    exit 1
fi
