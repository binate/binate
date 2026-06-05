# Conformance matrix

A systematic, **coordinate-addressed** body of conformance tests for the
managed-value refcount discipline (the code-red's "every cell must be
exercised" thesis — see `explorations/plan-code-red.md` §7). Each test's
identity is its *coordinates*, encoded as its path, not an allocated number:

    conformance/matrix/<form>/<shape>/<type>.bn   (+ .expected)

Because the path *is* the coordinates, names are **stable and collision-free**:
two workers adding different cells touch different paths by construction, and
nothing ever needs renumbering (so no references in code/plans/todos break).
A generator will eventually fill the product from one axes table; regeneration
is idempotent (same coordinates → same path), so adding a dimension value
creates new paths and touches nothing existing. The hand-authored cells here
pin the pattern the generator reproduces.

Paths must not contain spaces (the runner word-splits them).

## The three dimensions

**form** — the construct that writes the managed value into a slot:

| form              | meaning                                              |
|-------------------|------------------------------------------------------|
| `var-init`        | `var x T = <v>`                                      |
| `assign`          | `x = <v>` (single `=`, `x` already declared)         |
| `multi-assign`    | `a, b = f()` (slot gets a destructured component)    |
| `short-var`       | `x := <v>`                                           |
| `multi-short-var` | `a, b := f()`                                         |
| `composite-lit`   | a managed value as a struct-literal field            |
| `array-lit`       | a managed value as an array-literal element          |
| `mslice-lit`      | a managed value as a managed-slice-literal element   |
| `return`          | `return <v>` (delivered to the caller)               |
| `param`           | passing `<v>` as a call argument (param-entry)        |
| `for-range-value` | the value binding of `for v in coll` over managed elems |

**shape** — the target shape that receives the value. It varies only for the
assignment forms; the other forms have a single *degenerate* shape (so the
3-level path stays uniform for the generator and the runner):

| shape         | meaning                  | applies to                              |
|---------------|--------------------------|-----------------------------------------|
| `ident`       | a plain variable `x`     | var-init, assign, short-var, multi-*    |
| `selector`    | a struct field `s.f`     | assign, multi-assign                    |
| `index-array` | an array element `a[i]`  | assign, multi-assign                    |
| `index-slice` | a slice element `s[i]`   | assign, multi-assign                    |
| `index-rawptr`| a raw-ptr element `p[i]` | assign, multi-assign                    |
| `blank`       | the discard target `_`   | assign, multi-assign, short-var, multi-* |
| `elem`        | the literal element slot | composite-lit, array-lit, mslice-lit    |
| `value`       | the delivered value      | return, for-range-value                 |
| `arg`         | the call argument slot   | param                                   |

**type** — the managed value flowing through the cell:

| type             | meaning                                            |
|------------------|----------------------------------------------------|
| `managed-ptr`    | `@T`                                               |
| `managed-slice`  | `@[]T`                                             |
| `func-value`     | a **capturing** `@func(...)` (the mortal case)     |
| `iface`          | `@Iface`                                           |
| `managed-struct` | a by-value struct with a managed field (save-copy-destroy) |

Not every `(form, shape, type)` triple is valid (e.g. `index-rawptr` × `var-init`
is meaningless); invalid cells are simply absent — absence *is* the documentation.

## What a cell asserts: refcount balance with a MORTAL source

Each cell constructs a **mortal** managed value — `make` / `make_slice` / a
capturing closure, **never an immortal string literal** (whose refcount never
moves, which is exactly the coincidence that hid the original bugs) — flows it
through the cell's `(form, shape, type)` operation, and asserts via
`rt.Refcount` that the refcount rises by exactly one per live alias and returns
to baseline when the alias is dropped. The `.expected` is the printed sequence
of refcounts.

Per-type refcount observation (the idiom each cell uses):

- `managed-ptr` — `rt.Refcount(bit_cast(*uint8, theValue))` directly.
- `managed-slice` — `rt.Refcount(bit_cast(*uint8, p[2]))` where
  `p = bit_cast(*int, &theSlice)` (word 2 of the 3-word header is the backing
  refptr).
- `func-value` — watch a **captured** tracer `@Counter`: the closure record
  holds one ref to it, so copying the `@func` (RefInc-ing the record) keeps the
  tracer alive even after the original is dropped — the observable proof the
  copy was balanced.
- `iface` — a managed `@Iface` holds a ref to its wrapped object, so the
  wrapped tracer `@Counter`'s refcount tracks the iface directly.
- `managed-struct` — watch a managed field's refcount through the by-value
  struct copy (`__copy_` / `__dtor_`).

## Modes and xfails

Cells run in every default conformance mode (and should be extended to the
native lanes). When a real defect makes a cell fail, mark it
`…/<type>.xfail.<mode>` with a one-line reason (per the Bug Discovery Protocol),
**not** by weakening the assertion. The hand-authored `assign/ident/*` cells
pass in `builder-comp`, `-int`, `-int-int`, and `-comp-comp-comp`.

## Gotchas (pinned while authoring)

- A **bare func literal in assignment position** (`existingVar = func(){…}`)
  fails to resolve its managed/raw flavour from the LHS — use a typed drop
  variable (as 587 does). Var-init (`var x @func() … = func(){…}`) is fine.
- `rt.Refcount` works in `-int-int` for a **single-file** test that imports
  `pkg/builtins/rt` directly; the `-int-int` xfails on 586/592 are the
  cross-package loader issue (136/383), not `rt.Refcount` itself.

## `../regressions/`

Hand-written bug repros (the §8 audit leads) live under
`conformance/regressions/<descriptive-name>.bn`, discovered by the same
recursive runner pass — semantic names there beat allocated numbers for the
same stability reason.
