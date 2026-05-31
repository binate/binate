# `ifaces/core/` — tier 0 + 0b interfaces

Holds `.bni` files for the always-bundled runtime essentials. Mirrors
the in-`pkg/`-tree layout: a tier-0 package `pkg/builtins/<X>` keeps
its interface file at `ifaces/core/pkg/builtins/<X>.bni`.

Holds `pkg/builtins/lang.bni` and `pkg/builtins/testing.bni` today.
`pkg/builtins/rt.bni` joins when Step 4 of
[`explorations/pkg-layout-plan.md`](../../explorations/pkg-layout-plan.md)
resumes (after a new BUILDER tarball ships with the
`bn_pkg__builtins__rt__…` symbol prefix baked in).
