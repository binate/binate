# bnc

Binate compiler. Compiles `.bn` source files to native executables via LLVM IR.

## Usage

```
bnc [flags] <file.bn|dir>
bnc --test --root <dir> <pkg/foo> [pkg/bar ...]
bnc --pkg <path> --root <dir> [flags]
```

When given a directory, all `.bn` files in it (excluding `_test.bn`) are compiled together.

## Flags

| Flag | Description |
|------|-------------|
| `-o <name>` | Output name |
| `-c` | Compile to `.o` files only (don't link) |
| `--emit-llvm` | Print LLVM IR to stdout |
| `--pkg <path>` | Compile a single package (requires `--root`) |
| `--root <dir>` | Project root for package resolution |
| `--runtime <path>` | Path to `binate_runtime.c` |
| `-g`, `--debug` | Emit DWARF debug info |
| `-v`, `--verbose` | Verbose logging |
| `--test` | Compile and run unit tests for the given packages |

## Examples

```sh
# Compile a single file
bnc hello.bn

# Compile with debug info
bnc -g -o myapp cmd/myapp/

# Emit LLVM IR
bnc --emit-llvm hello.bn

# Run unit tests for a package
bnc --test --root . pkg/lexer pkg/parser
```
