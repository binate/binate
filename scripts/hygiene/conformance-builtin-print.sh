#!/bin/sh
# Usage: ./scripts/hygiene/conformance-builtin-print.sh
#
# Fails if any conformance test program uses the bare `print` / `println`
# BUILTIN. Those builtins are being retired from test programs in favor of
# `pkg/builtins/testing`'s `testing.Print` / `testing.Println` (which mirror the
# builtins byte-for-byte but are ordinary library functions). This check keeps
# the conformance corpus from silently re-growing builtin usage as new tests are
# added — the sweep that converted the corpus stays done only if new tests can't
# reintroduce the builtin unnoticed.
#
# A file legitimately ON the builtin (a test of the builtin's OWN behavior, or a
# case testing.Println cannot yet express) is listed, one conformance-relative
# path per line, in conformance-builtin-print.allow. Keep that list SMALL and
# justify each entry with a comment there.
#
# Detection: a bare `print(` / `println(` call — i.e. not preceded by `.`
# (so `testing.Println(` / `fmt.Println(` are fine) and not a substring of a
# longer identifier (`sprint(` etc.) — on a non-comment line. `//` line comments
# are stripped before matching so a doc mention of `println(...)` is not flagged.
#
# Exit code: 1 if any non-allowlisted violation is found, 0 otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALLOW="$SCRIPT_DIR/conformance-builtin-print.allow"
PAT='(^|[^.a-zA-Z_])(print|println)[[:space:]]*\('

status=0
# Narrow to candidate files first (fast), then confirm the match is real code
# (not a stripped comment) and the file is not allowlisted.
for f in $(grep -rlE "$PAT" "$REPO/conformance" --include='*.bn' 2>/dev/null | sort); do
    rel="${f#"$REPO"/}"
    if [ -f "$ALLOW" ] && grep -qxF "$rel" "$ALLOW"; then
        continue
    fi
    if sed 's|//.*||' "$f" | grep -qE "$PAT"; then
        if [ "$status" -eq 0 ]; then
            echo "conformance tests must use testing.Print/Println, not the print/println builtin:" >&2
        fi
        echo "  $rel" >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "(convert with testing.Print/Println; if the test is builtin-specific, add it to" >&2
    echo " scripts/hygiene/conformance-builtin-print.allow with a justification)" >&2
fi
exit $status
