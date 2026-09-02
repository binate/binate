# `ifaces/toolchain/` — shipped toolchain-package interfaces

Interfaces of **tier-2 toolchain packages** (`pkg/binate/...`) that ship in a
release bundle even though their implementation does not. A normal tier-2
package collocates its `.bni` and `.bn` under `pkg/` and is never bundled; a
package here is the exception — its interface must reach a released toolchain's
consumers, while its impl reaches them another way (or not at all).

## Contents

- `pkg/binate/link.bni` — the self-hosted linker's driver-facing interface.
  bnld's `-driver` mode runs an interpreted driver with link's *compiled*
  instance injected (via link's `__Package()` descriptor), so the driver's
  `link.*` calls resolve to the injected code. The driver only needs the
  interface to type-check; link's impl (`pkg/binate/link/*.bn`, tier 2, with
  tier-2 dependencies) is never compiled from the bundle. Shipping the impl
  would pull in unshippable tier-2 deps — shipping the interface alone is both
  sufficient and correct.

## Search-path wiring

`scripts/binate-paths.sh` lists `<base>/ifaces/toolchain` on `-I` alongside
`ifaces/core` and `ifaces/stdlib`, so any build against a source checkout or a
bundle resolves `import "pkg/binate/link"` from here. The BUILDER-based
bootstrap builds of `cmd/bnc` and `cmd/bnld` additionally `--prepend` the source
`ifaces/toolchain` (their `--base` is the frozen BUILDER lib, which predates this
tree). The loader skips a nonexistent `-I` dir, so listing `ifaces/toolchain`
unconditionally is safe for a BUILDER lib or an older bundle that lacks it.
