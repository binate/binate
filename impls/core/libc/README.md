# `impls/core/libc/` — tier 0 + 0b, libc target

libc-using `.bn` files for tier-0 / 0b packages — implementations
that rely on libc for syscall-like functionality (allocator,
filesystem, etc.).

Selected alongside `impls/core/common/` when building for a
libc-backed target.

Currently empty; populated as libc-backed implementations land.
