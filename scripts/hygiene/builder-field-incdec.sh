#!/bin/sh
# Usage: ./scripts/hygiene/builder-field-incdec.sh
#
# Rejects an increment or decrement statement whose operand is a field — `x.f++`,
# `x.f--`, `p.a.b++`, `(x.f)++` — in the BUILDER-compiled tree
# (scripts/lib/builder-tree.sh: cmd/bnc and the tree packages in its import closure,
# `.bni` files included; test files are not part of it).  Write `x.f += 1` /
# `x.f -= 1` there instead.
#
# The pinned BUILDER, bnc-0.0.16, predates binate 1f29d31e9: such a statement opening
# a loop, `if`, `else` or `case` body, or right after an `if`, `for` or `switch`, is
# emitted after the previous block's terminator, so gen1 gets undefined behavior
# there: a trap, a crash, or code silently not run.  `x.f += 1` compiles right.  The
# check bans the statement everywhere in that tree, not only in those positions, so
# a statement moved there cannot bring this form of the bug back.  (1f29d31e9 fixed
# two more forms, which a scan of the text cannot find; the todo entry on the
# constraint lists them.)  The check can go once BUILDER_VERSION includes
# 1f29d31e9.
#
# Each file is scanned whole, with its string and character literals and its
# comments blanked out in one pass, so neither prose nor a literal trips it and a
# statement split over lines does not escape it.  The check fails, rather than
# passing, when the walk of the tree does not reach the packages it must or a file
# cannot be read.
#
# Exit code: 1 if any such statement is found, 2 if the scan could not be done, 0
# otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BINATE_DIR" || exit 2
. "$BINATE_DIR/scripts/lib/builder-tree.sh"

PKGS=$(mktemp -t hygiene-incdec-pkgs.XXXXXX)
FILES=$(mktemp -t hygiene-incdec-files.XXXXXX)
FOUND=$(mktemp -t hygiene-incdec-found.XXXXXX)
ERRS=$(mktemp -t hygiene-incdec-errs.XXXXXX)
SCAN=$(mktemp -t hygiene-incdec-scan.XXXXXX)
trap 'rm -f "$PKGS" "$FILES" "$FOUND" "$ERRS" "$SCAN"' EXIT

# A walk that failed part-way (a tool missing, say) lists fewer packages; these
# are deep in cmd/bnc's closure, so it must reach them.
builder_tree_packages "$BINATE_DIR" > "$PKGS"
for need in cmd/bnc pkg/binate/check pkg/binate/irgen pkg/binate/native/common; do
    if ! grep -qxF "$need" "$PKGS"; then
        echo "FAIL: the walk of the BUILDER-compiled tree did not reach $need"
        exit 2
    fi
done
while read -r pkg; do
    _bt_pkg_files "$BINATE_DIR" "$pkg"
done < "$PKGS" | sed "s|^$BINATE_DIR/||" | sort -u > "$FILES"

cat > "$SCAN" <<'PERL'
# Report each field ++ / -- statement in the files named on the command line, as
# file:line: text.  Literals and comments are blanked first, in one pass, keeping
# newlines, so line numbers stay right and a statement split across lines is seen.
use strict;
use warnings;
my $bad = 0;
for my $f (@ARGV) {
    open(my $fh, '<', $f) or do { print STDERR "cannot read $f: $!\n"; $bad = 1; next };
    local $/;
    my $src = <$fh>;
    close($fh);
    (my $code = $src) =~ s{("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|//[^\n]*|/\*.*?\*/)}{
        (my $b = $1) =~ s/[^\n]/ /g; $b
    }gse;
    while ($code =~ /\.\s*[A-Za-z_]\w*[\s)]*(?:\+\+|--)/g) {
        my $line = 1 + (substr($code, 0, $-[0]) =~ tr/\n//);
        my @lines = split(/\n/, $src, -1);
        print "$f:$line: $lines[$line - 1]\n";
    }
}
exit($bad);
PERL

# shellcheck disable=SC2046  # one path per line, none with spaces
if ! perl "$SCAN" $(cat "$FILES") > "$FOUND" 2> "$ERRS" || [ -s "$ERRS" ]; then
    echo "FAIL: scanning the BUILDER-compiled tree failed:"
    sed 's/^/  /' "$ERRS"
    exit 2
fi

if [ -s "$FOUND" ]; then
    echo "FAIL: a field ++/-- in the BUILDER-compiled tree (write x.f += 1 / x.f -= 1):"
    sed 's/^/  /' "$FOUND"
    exit 1
fi
echo "OK: no field ++/-- in the BUILDER-compiled tree"
exit 0
