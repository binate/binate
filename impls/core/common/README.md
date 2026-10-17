# `impls/core/common/` — tier 0 + 0b, platform-independent

Platform-independent `.bn` files for tier-0 / 0b packages —
implementations whose source doesn't depend on the target's runtime
environment (e.g., the canonical primitive-type impls under
`pkg/builtins/lang`).

Holds `pkg/builtins/lang/` (canonical-impl carve-out: Stringer /
Comparable / Orderable / Hashable + their primitive impls),
`pkg/builtins/testing/` (the testing framework and its self-test),
`pkg/builtins/rt/`, `pkg/builtins/reflect/`, `pkg/builtins/softfloat/`
and `pkg/builtins/startup/`.
