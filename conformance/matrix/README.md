# Conformance matrices

A family of **coordinate-addressed** conformance test sets, one per recurring
defect class from the code-red taxonomy (see `explorations/plan-code-red.md`
§7). Each matrix systematically covers the product of its axes; the path
encodes the coordinates, so names are stable and collision-free and a generator
can regenerate idempotently.

    conformance/matrix/<class>/<axes...>.bn   (+ .expected)

Each class needs its own axes **and** its own correctness assertion — a
refcount-balance check can't see a wrong *value*; a value-correctness check
can't see a leak — so the classes are separate subtrees with their own
generators and READMEs. These matrices are distinct from
`conformance/regressions/`, which holds hand-written point-tests for one-off /
long-tail bugs that aren't a systematic product.

## Matrices

- **`refcount/`** — the managed-value refcount discipline (Class 1). Axes
  `<form>/<shape>/<type>`; assertion: a mortal value's refcount rises by one per
  live alias and returns to baseline. Generator: `conformance/gen-matrix.py`.
  See `refcount/README.md`.
- **`scalar/`** — sub-word & 64-on-32 scalar *value correctness* (Class 5). Axes
  `<op>/<width>/<sign>`; assertion: a sub-word op's result equals the math at
  the correct width (operands chosen to expose dirty-upper-bit defects).
  Generator: `conformance/gen-scalar-matrix.py`. See `scalar/README.md`.

Planned (each a new subtree + generator, reusing this infrastructure):

- **`abi/`** — aggregate & multi-return passing (Class 4): the bytes/values of
  an aggregate survive across every call shape and return.
- **`const/`** — constant materialization: a const's value at every scope and
  read form.

The runner discovers every `*.bn` under `conformance/matrix/` recursively, so
adding a matrix needs no runner change.
