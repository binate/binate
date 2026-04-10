# bni

Binate interpreter. Parses and directly interprets `.bn` source files.

## Usage

```
bni [flags] <file.bn|dir> [-- progargs...]
bni --test [-root <dir>] <pkg/foo> [pkg/bar ...]
```

When given a directory, all `.bn` files in it (excluding `_test.bn`) are interpreted together. Arguments after `--` are passed to the program as its command-line arguments.

## Flags

| Flag | Description |
|------|-------------|
| `-root <dir>` | Project root for package resolution |
| `-add-root <dir>` | Additional root for package resolution (repeatable) |
| `-v`, `-verbose` | Verbose logging |
| `-test`, `--test` | Run unit tests for the given packages |

## Examples

```sh
# Run a program
bni hello.bn

# Run a directory-based program with arguments
bni cmd/myapp/ -- --flag value

# Run unit tests for packages
bni --test -root . pkg/lexer pkg/parser
```
