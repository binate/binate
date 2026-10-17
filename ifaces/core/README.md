# `ifaces/core/` — tier 0 + 0b interfaces

Holds `.bni` files for the always-bundled runtime essentials. Mirrors
the in-`pkg/`-tree layout: a tier-0 package `pkg/builtins/<X>` keeps
its interface file at `ifaces/core/pkg/builtins/<X>.bni`.

Holds the interfaces of the `pkg/builtins/...` packages: `lang`, `rt`,
`reflect`, `testing` (and `testing/sys`), `build`, `softfloat` and
`startup`.
