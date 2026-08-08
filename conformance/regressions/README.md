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
  single-value materialization, which the `const` matrix covers). Integer
  arithmetic / bitwise / shift / parenthesized / const-of-const fold correctly;
  **non-integer** const-exprs are broken: IR-gen's `evalConstExpr` is int-only,
  so a binary-float / bool-comparison / const-as-array-dimension initializer is
  silently dropped and read back as `int 0` (all backends; filed). The `*-add`,
  `*-div`, `*-mul`, `bool-comparison`, and `array-dim` cells are xfailed.
- **`c-call/`** — the `__c_call` (C-ABI FFI) call shape, self-contained against
  already-linked libc (`abs` / `labs` / `strlen` / `printf`). All cells xfail
  the VM modes (FFI is compiled-mode-only) and the
  arm32 modes (no native arm32 backend yet). `printf-variadic-float`
  additionally xfails the native backends: a variadic `double` is passed wrong
  (x64-SysV needs `AL`=vector-count; darwin-arm64 stacks varargs) → printf reads
  `0` (filed).
