# Conformance regressions

Curated, hand-authored point-tests for one-off / long-tail bugs that are **not**
a systematic product — the complement to `../matrix/` (which holds the
coordinate-addressed matrices). The runner discovers every `*.bn` here
recursively and names each test by its path relative to `conformance/`, so
`<name>.expected` and `<name>.xfail.<mode>` resolve as siblings.

Add a regression test when a bug is a specific point in the space (a particular
construct, ordering, or call) rather than a cell in a covered product. When the
bug *is* a product (every type, every read-form, every backend), it belongs in a
matrix instead.

## Suites

- **`const-expr/`** — compile-time const-*expression* folding (distinct from
  single-value materialization, which the `const` matrix covers): integer
  arithmetic / bitwise / shift / parenthesized / const-of-const, and the
  **non-integer** forms — a binary-float / bool-comparison /
  const-as-array-dimension initializer, which an int-only fold would silently
  drop and read back as `int 0` (on all backends).
- **`c-call/`** — the `__c_call` (C-ABI FFI) call shape, self-contained against
  already-linked libc (`abs` / `labs` / `strlen` / `printf`). All cells xfail
  the VM modes (FFI is compiled-mode-only) and arm32-baremetal (no libc).
  `printf-variadic-float` pins a variadic `double` (x64-SysV needs
  `AL`=vector-count; darwin-arm64 stacks varargs); passed wrong, printf reads
  `0`.
