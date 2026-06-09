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
- **`scalar-diff/`** — property-based **differential** value-correctness for
  scalar shifts & conversions (the exhaustive-volume layer beneath `scalar/`).
  The oracle is the **spec** (computed at full precision), not a backend, so a
  value wrong on *every* backend is caught too. Each cell sweeps a fixed,
  seeded value set per coordinate and is self-checking
  (`println(cast(int, computed == spec_expected))` → `1`) for target-stability.
  Generator: `conformance/gen-diff-scalar.py`. See `scalar-diff/README.md`.
- **`abi/`** — aggregate & multi-return passing (Class 4). Categories
  `multi-return` / `struct-return` / `struct-param`, plus the call-shape axis
  `iface-param` / `funcval-param` (the same struct by value through an indirect
  call); assertion: every field's value survives the call boundary (shapes
  chosen to hit the non-8-multiple / padding / sub-word / >16-byte / high-arity
  edges). Generator: `conformance/gen-abi-matrix.py`. See `abi/README.md`.
- **`const/`** — compile-time constant materialization. Axes
  `<read-form>/<type>/<value>`; assertion: a constant materializes to the exact
  bit pattern of its type (printed as target-stable 16-bit lanes). The read-form
  axis (var-init / named-const / const-group / local-const / call-arg / field /
  return) is the discriminator — the front-end narrows at some positions but not
  others. Generator: `conformance/gen-const-matrix.py`. See `const/README.md`.

- **`addr-aggregate/`** — 16-byte address-aggregate (2-word) value handling
  (Class 2). Axes `<kind>/<operation>` where kind = `@func` / `@Iface` and
  operation = direct / copy / return / arg / return-arg / field / array-elem;
  assertion: both words survive the operation (observed by invoking the value →
  42). Generator: `conformance/gen-addr-aggregate-matrix.py`. See
  `addr-aggregate/README.md`.
- **`aggregate/`** — value-movement correctness for plain (non-managed)
  values. Axes `<form>/<kind>` where form = decl-init / assign / copy / deref /
  global / field / param / return and kind = `{scalar,array,struct}-{int,float}`;
  assertion: every lane (element / field / scalar) reads back its value after the
  movement (`println(cast(int, access == lit))` → 1). Fills the gap left by
  `abi` (call-boundary passing), `refcount` (managed lifecycle), and `const`
  (const materialization): plain var assignment / copy / deref-store / global
  initializer value correctness. Generator: `conformance/gen-aggregate-matrix.py`.
  See `aggregate/README.md`.
- **`globals/`** — package-level global/static storage materialization across
  type shapes (Code-Red-2 Class A). Axes `<storage>/<type>` where storage =
  init / noinit / readonly and type sweeps scalars, aggregates, managed/iface/func
  values, and the **named-wrapper** forms; assertion: the global compiles and
  reads back its value on every backend (the named-over-aggregate cells are
  red on LLVM — the codegen zero-token dispatch never peels `TYP_NAMED`).
  Generator: `conformance/gen-globals-matrix.py`. See `globals/README.md`.
- **`readonly/`** — the `readonly` type-modifier as a transparent wrapper
  (Code-Red-2 Class B). Axes `<operation>/<shape>`; assertion: a readonly view
  observes the same value / dispatch as the plain value (a missed `TYP_READONLY`
  peel is a silent literal-0 read or a spurious compile error). Includes the
  Round-2 wrapper-order (`@readonly Box` vs `readonly @Box`), alias-receiver, and
  readonly-iface-construct sibling axes. Generator:
  `conformance/gen-readonly-matrix.py`. See `readonly/README.md`.
- **`nested-index/`** — field/element access through a (possibly nested) array
  index base (Code-Red-2 path-parity family). Axes `<op>/<shape>`; assertion: a
  field/element reads back its written value (the nested-`[N][M]` × field-selector
  cells are red — `getIndexElemType` doesn't recurse the nested base, so
  `a[i][j].f` reads 0 / writes nowhere). Generator:
  `conformance/gen-nested-index-matrix.py`. See `nested-index/README.md`.
- **`operator/`** — operator lowering across the `op × width/sign × wrapper` grid
  (Code-Red-2 Class C, the targeted layer). Currently the unary sub-grid
  (`neg`/`bitnot` × widths × plain/named); assertion: the unary result equals the
  spec value at the operand's width (the named sub-word `neg` cells are red on
  LLVM — the MINUS arm never peels `TYP_NAMED`). Generator:
  `conformance/gen-operator-matrix.py`. See `operator/README.md`.

The runner discovers every `*.bn` under `conformance/matrix/` recursively, so
adding a matrix needs no runner change.
