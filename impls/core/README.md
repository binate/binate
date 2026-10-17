# `impls/core/` — tier 0 + 0b implementations

Holds `.bn` files for the always-bundled runtime essentials.

Per-platform leaves:

- `common/` — platform-independent code.
- `libc/` — libc-using implementations.
- (Future) `baremetal/` — bare-metal implementations.

A given package's files come from exactly one platform variant; the
loader consumes `common/` plus the chosen target via separate `-L`
entries.

`common/` holds the impls of the `pkg/builtins/...` packages (`lang`,
`rt`, `reflect`, `testing`, `softfloat`, `startup`); per-target bodies
are selected with per-file `#[build(...)]` gating (e.g. `rt`'s
bare-metal allocator in `rt/rt_baremetal.bn`).  `libc/` is currently
empty.
