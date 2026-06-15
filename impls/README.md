# `impls/` — implementation files

Parallel-tree root for `.bn` implementation files belonging to bundled
tiers (0, 0b, 1, 1x). Tier-organized first.

Subtrees:

- `core/` — tier 0 + 0b implementations.
- `stdlib/` — tier 1 + 1x implementations.

`core/` splits per-platform leaves: `common/` (always valid), `libc/`, and
(eventually) `baremetal/`; a package's files come from one platform variant,
with `common/` included alongside the chosen target. `stdlib/` keeps a single
flat `pkg/` tree instead and selects platform-specific bodies with per-file
`#[build(...)]` gating (see `impls/stdlib/README.md`, which also documents the
transitional `common` compat symlink).

Tier 2 / 3 packages collocate `.bni` and `.bn` under `pkg/` rather
than living here.

See [`explorations/pkg-layout-spec.md`](../explorations/pkg-layout-spec.md)
for the full layout contract.
