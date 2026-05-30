# `impls/` — implementation files

Parallel-tree root for `.bn` implementation files belonging to bundled
tiers (0, 0b, 1, 1x). Tier-organized first, then split by platform.

Subtrees:

- `core/` — tier 0 + 0b implementations.
- `stdlib/` — tier 1 + 1x implementations.

Each tier subtree has per-platform leaves: `common/` (always valid),
`libc/`, and (eventually) `baremetal/`. A given package's files come
from one platform variant; `common/` is included alongside the chosen
target.

Tier 2 / 3 packages collocate `.bni` and `.bn` under `pkg/` rather
than living here.

See [`explorations/pkg-layout-spec.md`](../explorations/pkg-layout-spec.md)
for the full layout contract.
