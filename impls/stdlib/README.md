# `impls/stdlib/` — tier 1 + 1x implementations

Holds `.bn` files for the bundled standards library (tier 1) and its
standards-track companion (tier 1x), in a single flat `pkg/` tree (mirroring
`ifaces/stdlib/pkg/`).

Unlike `impls/core/` — which splits platform variants into `common/` / `libc/`
/ `baremetal/` directories — stdlib needs no per-platform leaves: a package
selects platform-specific bodies with per-file `#[build(...)]` gating (e.g.
`pkg/std/os/os_errno_darwin.bn` vs `os_errno_linux.bn`), all under `pkg/`.

See [`explorations/pkg-layout-spec.md`](../../explorations/pkg-layout-spec.md)
for the full layout contract.
