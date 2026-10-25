#!/bin/sh
# Usage: ./scripts/bnfmt-check/corpora.sh <out dir>
#
# Build the corpora compare.sh checks bnfmt on, from this tree, into <out dir>:
#
#   tree      the tree's .bn files (listed, not copied)
#   gen       generated statement mixes (gen_mix.py, seeds 1-10, 300 each)
#   genb      the same, denser in comments and function literals (seeds 11-20)
#   sweep     adjacent-string runs in sixteen places (gen_sweep.py)
#   rv        calls, postfix chains and switch labels (gen_review.py)
#   fuzz      tree files with comments injected (inject_comments.py)
#   p-<mode>  500 tree files with wrapped lists, perturbed (perturb.py)
#
# and <out dir>/lists/<corpus>.txt, each corpus's files.  The generated corpora
# depend only on these scripts; fuzz and p-* also on the tree.
set -e
# One collation for every list, so the corpora do not depend on the locale.
LC_ALL=C
export LC_ALL
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINATE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ $# -ne 1 ]; then
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
    exit 2
fi
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
L=$OUT/lists
for c in gen genb sweep rv fuzz p lists; do rm -rf "${OUT:?}/$c"; done
mkdir -p "$L"
py() { script=$1; shift; python3 -I "$SCRIPT_DIR/$script" "$@"; }

for s in 1 2 3 4 5 6 7 8 9 10; do py gen_mix.py "$s" 300 "$OUT/gen"; done
for s in 11 12 13 14 15 16 17 18 19 20; do py gen_mix.py --dense "$s" 300 "$OUT/genb"; done
py gen_sweep.py "$OUT/sweep"
py gen_review.py calls 101 500 "$OUT/rv"
py gen_review.py calls-short 202 500 "$OUT/rv"
py gen_review.py postfix 303 500 "$OUT/rv"
py gen_review.py switch 404 500 "$OUT/rv"

cd "$BINATE_DIR"
F=$OUT/fuzz
mkdir -p "$F"
ls pkg/binate/format/*.bn | grep -v _test > "$F/files1.txt"
ls pkg/binate/check/*.bn pkg/binate/parser/*.bn pkg/binate/irgen/*.bn \
    pkg/binate/native/aarch64/*.bn pkg/binate/lint/*.bn | grep -v _test | head -250 \
    > "$F/files2.txt"
# Each file once per list: an injection's output is named by its input's path.
{ grep -rl '__c_call' --include='*.bn' pkg runtime impls | sort | head -60
  ls pkg/binate/format/*_test.bn pkg/binate/check/*_test.bn | head -80
  ls conformance/*.bn | head -150; } | awk '!seen[$0]++' > "$F/files3.txt"
cat "$F/files2.txt" "$F/files3.txt" | awk '!seen[$0]++' > "$F/files23.txt"
py inject_comments.py 1 1 "$F/c1" $(cat "$F/files1.txt")
py inject_comments.py 1 7 "$F/c2" $(cat "$F/files2.txt")
py inject_comments.py 1 11 "$F/c3" $(cat "$F/files3.txt")
py inject_comments.py 2 3 "$F/c4" $(cat "$F/files3.txt")
for s in 21 22; do py inject_comments.py 2 "$s" "$F/c$s" $(cat "$F/files23.txt"); done
for s in 31 32; do py inject_comments.py 3 "$s" "$F/c$s" $(cat "$F/files23.txt"); done

P=$OUT/p
mkdir -p "$P"
find pkg cmd impls ifaces perf examples runtime -name '*.bn' | sort \
    | sed "s|^|$BINATE_DIR/|" > "$P/all.txt"
python3 -I - "$P/all.txt" "$P/sample.txt" <<'EOF'
import random, sys
random.seed(7)
with open(sys.argv[1]) as f:
    files = [ln.strip() for ln in f]
def wrapped(path):
    with open(path) as f:
        return sum(1 for ln in f if ln.rstrip().endswith((',', '('))) >= 3
with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(random.sample([p for p in files if wrapped(p)], 500)) + '\n')
EOF
for m in id str join split cmt mix; do py perturb.py "$P/sample.txt" "$P/p-$m" 1 "$m"; done

find pkg cmd impls ifaces perf examples runtime conformance e2e -name '*.bn' | sort \
    | sed "s|^|$BINATE_DIR/|" > "$L/tree.txt"
for c in gen genb sweep rv fuzz; do find "$OUT/$c" -name '*.bn' | sort > "$L/$c.txt"; done
for m in id str join split cmt mix; do
    find "$P/p-$m" -name '*.bn' | sort > "$L/p-$m.txt"
done
wc -l "$L"/*.txt
