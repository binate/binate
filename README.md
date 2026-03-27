# Binate

The self-hosted Binate toolchain — interpreter, compiler, and supporting packages — written in Binate itself.

This repository is bootstrapped using the [Go bootstrap interpreter](https://github.com/binate/bootstrap), which runs the code here until the compiler can compile itself.

## Status

Self-hosted interpreter is working. The interpreter can interpret itself (double interpretation verified: bootstrap interprets `main.bn`, which interprets `main.bn`, which interprets a target program). The package loader discovers and resolves multi-package projects. Next milestone: self-hosted compiler (Phase 5b).

## Quick Start

Requires Go and the [bootstrap interpreter](https://github.com/binate/bootstrap):

```sh
# Clone both repos
git clone https://github.com/binate/bootstrap.git
git clone https://github.com/binate/binate.git

# Run a program
cd bootstrap
go run . -root ../binate ../binate/main.bn -- ../binate/selftest.bn

# Double interpretation (bootstrap -> main.bn -> mini_driver.bn -> program.bn)
go run . -root ../binate ../binate/main.bn -- ../binate/mini_driver.bn -- ../binate/selftest.bn

# Run unit tests for a package
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/interp pkg/loader

# Run with verbose logging (-v works at both bootstrap and self-hosted level)
go run . -v -root ../binate ../binate/main.bn -- -v ../binate/selftest.bn

# Run conformance tests
cd ../binate && ./conformance/run.sh bootstrap
```

## Project Structure

```
binate/
  main.bn                  Self-hosted driver (parse, load, interpret)
  mini_driver.bn           Lightweight driver for double-interpretation testing
  selftest.bn              Quick self-test (arithmetic, strings, loops, recursion)
  conformance/             Conformance test suite (shared across backends)
    run.sh                 Test runner (bootstrap / selfhost modes)
    NNN_name.bn            Test programs
    NNN_name.expected       Expected stdout
  pkg/
    token/                 Token types, positions, keyword lookup
    ast/                   AST node types (Decl, Expr, Stmt, File)
    lexer/                 Tokenizer with automatic semicolon insertion
    parser/                Recursive descent parser
    types/                 Type system (Type struct with Kind enum)
    interp/                Tree-walking interpreter, values, environments
    loader/                Package discovery, loading, merging, topological sort
    debug/                 Verbose logging (SetVerbose, Log)
    builtin/testing/       Test framework (TestResult type alias)
    bootstrap.bni          Interface for bootstrap-provided OS primitives
```

## Architecture

### Execution Model

Programs run through three stages:

1. **Parse**: Source files are tokenized (lexer) and parsed (parser) into AST nodes.
2. **Load**: The package loader discovers imported packages on disk, parses their `.bn`/`.bni` files, merges multi-file packages, and computes a dependency-ordered load sequence via topological sort.
3. **Interpret**: The tree-walking interpreter evaluates AST nodes directly. Packages are loaded in dependency order, each getting its own environment. The main package runs last.

### Verbose Logging

All three layers support `-v` for debug logging to stderr:

```sh
# Bootstrap verbose (package loading, type checking, interpreter)
go run . -v -root ../binate ../binate/main.bn -- program.bn

# Self-hosted interpreter verbose (parsing, loading, interpreter entry)
go run . -root ../binate ../binate/main.bn -- -v program.bn

# Compiler verbose (parsing, IR generation, LLVM emission)
go run . -root ../binate ../binate/compile.bn -- -v program.bn

# Both layers verbose at once
go run . -v -root ../binate ../binate/main.bn -- -v program.bn
```

The `pkg/debug` package provides `SetVerbose`, `IsVerbose`, and `Log` for use in self-hosted code. `Log` writes `[verbose] msg` to stderr only when verbose mode is active.

### Double Interpretation

The self-hosted interpreter can interpret itself:

```
Go bootstrap
  -> interprets main.bn (self-hosted driver)
    -> interprets main.bn (or mini_driver.bn)
      -> interprets target.bn
```

This works because the bootstrap forwarding layer (`pkg/interp/bootstrap_fwd.bn`) bridges the gap: when interpreted code calls `bootstrap.Open()`, `bootstrap.Read()`, etc., the forwarding layer dispatches these to the real bootstrap functions provided by the Go runtime.

### Packages

Binate uses a filesystem-based package system. Each package has:

- **`.bni` file** (optional): Interface declarations (types, constants, function signatures without bodies). Located at `pkg/name.bni`.
- **`.bn` files**: Implementation files in a directory at `pkg/name/`. Multiple `.bn` files in the same directory are merged into one package.

```
myproject/
  main.bn                    package "main"
  pkg/
    math.bni                 interface: type declarations, func signatures
    math/
      math.bn                implementation
      helpers.bn             additional implementation (merged)
```

Import and use:
```
import "pkg/math"

func main() {
    println(math.Add(2, 3))
}
```

### pkg/bootstrap

The `pkg/bootstrap` package provides OS-level primitives. In the Go bootstrap, these are backed by Go's standard library. In the self-hosted interpreter, they are forwarded through `RegisterBootstrapPackage`.

| Function | Signature | Description |
|----------|-----------|-------------|
| `Open`   | `(path []char, flags int) int` | Open file, returns fd |
| `Read`   | `(fd int, buf []uint8, n int) int` | Read bytes into buffer |
| `Write`  | `(fd int, buf []uint8, n int) int` | Write bytes from buffer |
| `Close`  | `(fd int) int` | Close file descriptor |
| `Exit`   | `(code int)` | Exit process |
| `Args`   | `() [][]char` | Program arguments (after `--`) |
| `Stat`   | `(path []char) int` | 0=not found, 1=file, 2=directory |
| `ReadDir`| `(path []char) [][]char` | Sorted directory entries |
| `Itoa`   | `(v int) []char` | Int to decimal string |
| `Concat` | `(a []char, b []char) []char` | String concatenation |

Constants: `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREATE`, `O_TRUNC`, `O_APPEND`, `STDIN`, `STDOUT`, `STDERR`.

## Testing

Three layers of testing:

### Unit Tests

Each package has `*_test.bn` files with `func TestXxx() testing.TestResult` functions. Run with the bootstrap's `-test` flag:

```sh
cd bootstrap
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/interp pkg/loader
```

Tests return `""` for pass, or a failure message string.

### Conformance Suite

Standalone `.bn` programs with expected output. These tests are shared across all execution backends (bootstrap, self-hosted interpreter, future compiler):

```sh
cd binate
./conformance/run.sh bootstrap    # Run via Go bootstrap
./conformance/run.sh selfhost     # Run via self-hosted interpreter
```

Each test is a `package "main"` program that prints to stdout. The runner compares actual output against the `.expected` file.

### Go-Level Tests

The bootstrap interpreter has its own Go test suite:

```sh
cd bootstrap
go test ./...
```

## Language

Binate is a systems programming language with dual-mode execution (compiled and interpreted), reference-counted memory management, and an embeddable interpreter. See the [explorations repo](https://github.com/binate/explorations) for language design documents.
