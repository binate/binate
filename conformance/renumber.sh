#!/bin/sh
# Usage: ./conformance/renumber.sh <test> [<target-number>]
#
# Renumber a conformance test, moving ALL of its files to a new number
# with `git mv` so history follows.  Only the NNN prefix changes; the
# _<name> suffix is preserved.
#
# <test> identifies the test to move, given as:
#   - the number alone   (e.g. 532) — must be unambiguous; if two tests
#     share that number (the collision case), pass the full stem instead
#   - the full stem      (e.g. 532_reflect_package_accessor)
# A test is single-file (NNN_<name>.bn + a .expected/.error sibling) or
# multi-file (NNN_<name>/ directory).  Either way, every associated file
# moves together: the .bn, the .expected/.error, every .xfail.<mode> and
# .expected.<mode> sidecar, and (multi-file) the directory itself.
#
# <target-number> is the destination NNN.  Default: the next free number
# (./conformance/next-number.sh).  An explicit target must be a free
# 3-digit number.
#
# Primary use: resolving the duplicate-number collisions that
# scripts/hygiene/conformance-test-numbers.sh flags when two branches
# both grabbed the same NNN.
#
# Exit code: 1 on any error (unknown test, ambiguous number, target in
# use, git mv failure), 0 on success.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFORMANCE_DIR="$SCRIPT_DIR"

die() { echo "renumber.sh: $1" >&2; exit 1; }

[ -n "$1" ] || die "usage: $0 <test> [<target-number>]"
INPUT="$1"
TARGET="$2"

# Strip a trailing slash a shell tab-completion might add to a dir arg.
INPUT="${INPUT%/}"

# Enumerate the stems (NNN_<name>) of all real tests.
test_stems() {
    for bn in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*.bn; do
        [ -f "$bn" ] || continue
        name="$(basename "$bn" .bn)"
        if [ -f "$CONFORMANCE_DIR/${name}.expected" ] || \
           [ -f "$CONFORMANCE_DIR/${name}.error" ]; then
            echo "$name"
        fi
    done
    for dir in "$CONFORMANCE_DIR"/[0-9][0-9][0-9]_*/; do
        [ -d "$dir" ] || continue
        basename "$dir"
    done
}

# Resolve INPUT to exactly one stem.
case "$INPUT" in
    [0-9][0-9][0-9])
        # Number alone — find the matching stem(s).
        MATCHES="$(test_stems | grep "^${INPUT}_" | sort -u)"
        ;;
    [0-9][0-9][0-9]_*)
        MATCHES="$(test_stems | grep -x "$INPUT" | sort -u)"
        ;;
    *)
        die "<test> must be a number (532) or a stem (532_name): got '$INPUT'"
        ;;
esac

[ -n "$MATCHES" ] || die "no test found for '$INPUT'"
count="$(echo "$MATCHES" | wc -l | tr -d ' ')"
if [ "$count" -gt 1 ]; then
    echo "renumber.sh: '$INPUT' is ambiguous — matches:" >&2
    echo "$MATCHES" | sed 's/^/  /' >&2
    die "pass the full stem to pick one"
fi
STEM="$MATCHES"
SRC_NUM="$(echo "$STEM" | cut -c1-3)"
NAME="$(echo "$STEM" | cut -c5-)"

# Determine the target number.
if [ -z "$TARGET" ]; then
    TARGET="$(sh "$CONFORMANCE_DIR/next-number.sh")" || die "next-number.sh failed"
fi
case "$TARGET" in
    [0-9][0-9][0-9]) ;;
    *) die "<target-number> must be a 3-digit number: got '$TARGET'" ;;
esac
if [ "$TARGET" = "$SRC_NUM" ]; then
    die "$STEM already has number $TARGET"
fi
if test_stems | grep -q "^${TARGET}_"; then
    die "target $TARGET is already in use by $(test_stems | grep "^${TARGET}_" | head -1)"
fi

NEW_STEM="${TARGET}_${NAME}"

# Move everything.  cd into conformance/ so git mv operands are the bare
# names the user sees, and so the moves are recorded against the repo.
cd "$CONFORMANCE_DIR" || die "cannot cd to $CONFORMANCE_DIR"

moved=0
# Multi-file directory (if any).
if [ -d "$STEM" ]; then
    git mv "$STEM" "$NEW_STEM" || die "git mv $STEM -> $NEW_STEM failed"
    echo "  $STEM/ -> $NEW_STEM/"
    moved=$((moved + 1))
fi
# Sibling files: NNN_<name>.<suffix> (the .bn, .expected/.error, and every
# .xfail.<mode> / .expected.<mode>).  The literal '.' after the stem keeps
# this from matching a longer-named sibling (NNN_<name>_more.bn).
for f in "$STEM".*; do
    [ -e "$f" ] || continue
    suffix="${f#${STEM}}"
    git mv "$f" "${NEW_STEM}${suffix}" || die "git mv $f failed"
    echo "  $f -> ${NEW_STEM}${suffix}"
    moved=$((moved + 1))
done

[ "$moved" -gt 0 ] || die "nothing moved for $STEM (no tracked files?)"
echo "renumbered $STEM -> $NEW_STEM ($moved file(s)/dir(s))"
