# `impls/stdlib/` — tier 1 + 1x implementations

Holds `.bn` files for the bundled standards library (tier 1) and its
standards-track companion (tier 1x), in a single flat `pkg/` tree (mirroring
`ifaces/stdlib/pkg/`).

Unlike `impls/core/` — which splits platform variants into `common/` / `libc/`
/ `baremetal/` directories — stdlib needs no per-platform leaves: a package
selects platform-specific bodies with per-file `#[build(...)]` gating (e.g.
`pkg/std/os/os_errno_darwin.bn` vs `os_errno_linux.bn`), all under `pkg/`.

`common` is a symlink to `.` (this directory). It is a transitional
BUILDER-compat shim: `scripts/binate-paths.sh` emits `$BASE/impls/stdlib/common`
as a search root, and the pinned BUILDER bundle still ships that as a real
directory, so the symlink lets that same search root resolve against this
flattened tree. Drop the symlink and switch binate-paths.sh to
`$BASE/impls/stdlib` once no pinned BUILDER ships the `common/` layout.

See [`explorations/pkg-layout-spec.md`](../../explorations/pkg-layout-spec.md)
for the full layout contract.
