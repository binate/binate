# `ifaces/` — interface declarations

Parallel-tree root for `.bni` interface files belonging to bundled
tiers (0, 0b, 1, 1x). One interface tree regardless of which `impls/`
variant is selected — interface shape never depends on platform.

Subtrees:

- `core/` — tier 0 + 0b interfaces (`pkg/builtins/...`).
- `stdlib/` — tier 1 + 1x interfaces (`pkg/std/...`, `pkg/stdx/...`).

Tier 2 / 3 packages collocate `.bni` and `.bn` under `pkg/` rather
than living here.

See [`explorations/pkg-layout-spec.md`](../explorations/pkg-layout-spec.md)
for the full layout contract.
