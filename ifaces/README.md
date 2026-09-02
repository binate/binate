# `ifaces/` — interface declarations

Parallel-tree root for `.bni` interface files belonging to bundled
tiers (0, 0b, 1, 1x). One interface tree regardless of which `impls/`
variant is selected — interface shape never depends on platform.

Subtrees:

- `core/` — tier 0 + 0b interfaces (`pkg/builtins/...`).
- `stdlib/` — tier 1 + 1x interfaces (`pkg/std/...`, `pkg/stdx/...`).
- `toolchain/` — interfaces of tier-2 toolchain packages that ship for
  a specific reason even though their impl does not. Currently only
  `pkg/binate/link.bni`: bnld injects link's compiled instance into an
  interpreted driver, so a driver type-checks against this shipped
  interface while the impl is never compiled from the bundle. See
  `toolchain/README.md`.

Tier 2 / 3 packages otherwise collocate `.bni` and `.bn` under `pkg/`
rather than living here; `toolchain/` is the deliberate exception for
interfaces that must reach a released toolchain's consumers.

See [`explorations/pkg-layout-spec.md`](../explorations/pkg-layout-spec.md)
for the full layout contract.
