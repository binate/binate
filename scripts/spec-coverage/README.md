# Spec Coverage

Cross-references the language specification's declared **rule-IDs** against the
`.rules` sidecars of the **spec conformance tests** (`conformance/spec/`), and
reports how much of the normative, testable surface is covered. Background and
phasing: `explorations/plan-spec-tests.md`.

## Running

```sh
scripts/spec-coverage/run.sh [-v] [--chapter NN] [--json out.json]
```

- `-v` — list the gap rule-IDs (not just the count).
- `--chapter NN` — restrict to spec chapter files matching `NN` (e.g. `13`).
- `--json PATH` — also emit machine-readable coverage (for Annex C derivation).
- `--rule-ids PATH` — read the inventory from `PATH` instead of the vendored copy.

It prints per-chapter and overall coverage %, then the three findings:

| Finding | Meaning | Fails the run? |
|---------|---------|----------------|
| **GAPS** | denominator rule-IDs with no spec test | no — driving these down is the work |
| **DANGLING** | a `.rules` sidecar cites a rule-ID the spec doesn't declare (typo / rename) | yes |
| **UNTAGGED** | a spec test with no `.rules` sidecar | yes |

This is the **static** half (it does not run the tests). Per-mode pass/xfail
status and the full Annex-C JSON are a later `--run` increment.

## The rule-ID inventory

`rule-ids.txt` is a **vendored snapshot** of `docs/spec/rule-ids.txt`, which the
spec repo generates from `docs/spec/*.md` via `docs/scripts/extract-rule-ids.py`.
It is tab-separated: `<rule-id>  <bucket>  <source-file>`.

Buckets and the coverage **denominator**:

| Bucket | In denominator? | Test artifact |
|--------|-----------------|---------------|
| `positive` | yes | `.bn` + `.expected` (assert the result) |
| `constraint` | yes | `.bn` + `.error` (must be rejected) |
| `constraint-candidate` | yes | likely `.error`; confirm per rule |
| `untestable` | no | non-observable by construction (allowlisted) |
| `framework` | no | metalanguage / definitions / back-reference index |

Refresh after the spec's rule-IDs change:

```sh
python3 docs/scripts/extract-rule-ids.py          # regenerate docs/spec/rule-ids.txt
cp docs/spec/rule-ids.txt scripts/spec-coverage/  # re-vendor
```

If a sibling `docs` checkout is present (`../docs` or `$BINATE_DOCS`), the tool
warns when the vendored copy has drifted from it.

## The `.rules` sidecar

One rule-ID per line (`#` comments and blank lines ignored); the **first**
non-comment line is the test's PRIMARY target, the rest are incidental coverage.

- single-file test `NNN_name.bn` → sidecar `NNN_name.rules`
- multi-package test `NNN_name/` → sidecar `NNN_name/NNN_name.rules`

A rule-ID may be covered by several tests (positive + negative + boundary), and
a test may cite several rule-IDs.
