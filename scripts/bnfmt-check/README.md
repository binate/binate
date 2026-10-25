# bnfmt-check

Scripts for checking a change to bnfmt (`pkg/binate/format`) beyond its unit
tests: run the changed build and its base on some 25,000 files, the tree's and
generated ones, and report where they differ, where formatting a file twice
does not give the same result (idempotence) or bnfmt rejects its own output,
where lines grow past the cap, and where an output's tokens or comments differ
from its input's.  They are a development aid, not part of hygiene or CI.

## Use

Build both formatters, the changed one and its base, from the same tree
(`scripts/build-bnfmt.sh -o <path>`, the base with the change reverted), then:

    scripts/bnfmt-check/corpora.sh <corpora dir>
    scripts/bnfmt-check/compare.sh <new bnfmt> <old bnfmt> <corpora dir> <out dir>

`compare.sh` prints a summary line per corpus, which also counts the files
both builds reject; `<out dir>/<corpus>.out` lists the findings (see
`check.py`).  For the `tree` corpus, `differs` lines are the
tree files the change lays out differently.  Pass the same build twice to
check one build: every finding is then `both`.

To study the files a second format changes (or rejects), collect and shrink
them:

    scripts/bnfmt-check/minimize.py collect <bnfmt> <dir> < <file list>
    scripts/bnfmt-check/minimize.py shrink <bnfmt> <dir>

which leaves each case, minimized, in `<dir>/min/<n>.min.bn`.

## Corpora

`corpora.sh` builds them from the tree it is in:

- `tree`: the tree's `.bn` files, read in place.
- `gen`, `genb`: random statement mixes (`gen_mix.py`): nested calls,
  composite and function literals, chains and string runs, with comments,
  line breaks and `// LONG-LINE ALLOWED` markers in their lists; `genb` has
  more comments and function literals.
- `sweep`: adjacent-string runs of every length near the cap's splits, in
  sixteen places (`gen_sweep.py`).
- `rv`: argument lists, postfix chains and switch labels (`gen_review.py`).
- `fuzz`: tree files with comments injected in their lists
  (`inject_comments.py`).
- `p-id`, `p-str`, `p-join`, `p-split`, `p-cmt`, `p-mix`: tree files with
  identifiers or strings lengthened, lines joined or split, or comments added
  (`perturb.py`).

The generated corpora depend only on the scripts' seeds, so a count from one
run compares with another's; `fuzz` and the `p-` corpora follow the tree.
