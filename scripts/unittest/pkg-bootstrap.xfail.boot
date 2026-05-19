bootstrap package's .bn impls are shadowed by Go shims under boot mode (interpreter/value.go etc.); testing them only makes sense via the compiled path.
