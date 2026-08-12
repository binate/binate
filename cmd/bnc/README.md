# bnc

Binate compiler. Compiles `.bn` source files to native executables via LLVM IR.

## Usage

```
bnc [flags] <file.bn|dir>
bnc --test -I <dir> <pkg/foo> [pkg/bar ...]
bnc --pkg <path> -I <dir> [flags]
```

When given a directory, all `.bn` files in it (excluding `_test.bn`) are compiled together.

Anything beyond a builtins-only program needs `-I`/`-L` search paths. For
building against a release bundle and its bundled stdlib, see
[`BUNDLE-HOWTO.md`](../../BUNDLE-HOWTO.md).

## Flags

| Flag | Description |
|------|-------------|
| `-o <name>` | Output name |
| `-c` | Compile to `.o` files only (don't link) |
| `--emit-llvm` | Print LLVM IR to stdout |
| `-I <dirs>` | Colon-separated dirs searched for `.bni` interface files (repeatable; later flags append). The first entry is the project root for package resolution. Falls back to `BINATE_PACKAGE_INTERFACE_PATH` (see Environment). |
| `-L <dirs>` | Colon-separated dirs searched for impl directories (repeatable). Falls back to `BINATE_PACKAGE_IMPL_PATH` (see Environment). |
| `--pkg <path>` | Compile a single package (requires `-I`) |
| `-g`, `--debug` | Emit DWARF debug info |
| `-v`, `--verbose` | Verbose logging |
| `--test` | Compile the given packages into a unit-test binary and print its path — run that binary to execute the tests |

## Environment

When the matching flag is absent, a search path is taken from the environment:

- `BINATE_PACKAGE_INTERFACE_PATH` (alias `BINATE_BNI_PATH`) — supplies `-I`.
- `BINATE_PACKAGE_IMPL_PATH` (alias `BINATE_IMPL_PATH`) — supplies `-L`.

Each is a colon-separated list, same syntax as the flag. The flag wins per path
(a path given on the command line ignores its env var); the long form wins over
the short alias when both are set.

## Examples

```sh
# Compile a single file
bnc hello.bn

# Compile with debug info
bnc -g -o myapp cmd/myapp/

# Emit LLVM IR
bnc --emit-llvm hello.bn

# Build a test binary for some packages, then run it
bin=$(bnc --test -I . pkg/binate/lexer pkg/binate/parser)
"$bin"
```
