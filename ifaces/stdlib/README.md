# `ifaces/stdlib/` — tier 1 + 1x interfaces

Holds `.bni` files for the bundled-by-default standards library and
its standards-track companion. Tier 1 (`pkg/std/...`) and tier 1x
(`pkg/stdx/...`) sit under one root because they bundle and select as
a single unit — the stability difference is per-package, not
per-tree.
