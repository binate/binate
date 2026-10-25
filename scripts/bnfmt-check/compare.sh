#!/bin/sh
# Usage: ./scripts/bnfmt-check/compare.sh <new bnfmt> <old bnfmt> <corpora dir> <out dir>
#
# Run check.py on each corpus corpora.sh built in <corpora dir>, writing each
# corpus's findings to <out dir>/<corpus>.out and printing its summary line:
# files the builds lay out differently, files a second format changes (new
# only, fixed, under both), files with more or fewer lines over the cap, and
# files whose tokens the new build alone changes.  Pass the same build twice
# to check one build.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ $# -ne 4 ]; then
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
    exit 2
fi
NEW=$1
OLD=$2
CORPORA=$3
OUT=$4
mkdir -p "$OUT"
for list in "$CORPORA"/lists/*.txt; do
    c=$(basename "$list" .txt)
    python3 -I "$SCRIPT_DIR/check.py" "$NEW" "$OLD" < "$list" > "$OUT/$c.out"
    echo "$c: $(tail -1 "$OUT/$c.out")"
done
