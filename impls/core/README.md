# `impls/core/` — tier 0 + 0b implementations

Holds `.bn` files for the always-bundled runtime essentials.

Per-platform leaves:

- `common/` — platform-independent code.
- `libc/` — libc-using implementations (e.g., libc-backed `pkg/builtins/rt`).
- (Future) `baremetal/` — bare-metal implementations.

A given package's files come from exactly one platform variant; the
loader consumes `common/` plus the chosen target via separate `-L`
entries.

Populated as tier-0 packages migrate (Steps 2-4 of
[`explorations/pkg-layout-plan.md`](../../explorations/pkg-layout-plan.md)).
