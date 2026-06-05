# bnc

Binate compiler. Compiles `.bn` source files to native executables via LLVM IR.

## Usage

```
bnc [flags] <file.bn|dir>
bnc --test -I <dir> <pkg/foo> [pkg/bar ...]
bnc --pkg <path> -I <dir> [flags]
```

When given a directory, all `.bn` files in it (excluding `_test.bn`) are compiled together.

Anything beyond a builtins-only program needs `-I`/`-L` search paths (and
`--runtime` to link). For building against a release bundle and its bundled
stdlib, see [`BUNDLE-HOWTO.md`](../../BUNDLE-HOWTO.md).

## Flags

| Flag | Description |
|------|-------------|
| `-o <name>` | Output name |
| `-c` | Compile to `.o` files only (don't link) |
| `--emit-llvm` | Print LLVM IR to stdout |
| `-I <dirs>` | Colon-separated dirs searched for `.bni` interface files (repeatable; later flags append). The first entry is the project root for package resolution. |
| `-L <dirs>` | Colon-separated dirs searched for impl directories (repeatable). |
| `--pkg <path>` | Compile a single package (requires `-I`) |
| `--runtime <path>` | Path to `binate_runtime.c` |
| `-g`, `--debug` | Emit DWARF debug info |
| `-v`, `--verbose` | Verbose logging |
| `--test` | Compile the given packages into a unit-test binary and print its path — run that binary to execute the tests |

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
