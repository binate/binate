# Binate

[![CI](https://github.com/binate/binate/actions/workflows/ci.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/ci.yml)

The self-hosted Binate toolchain — interpreter, compiler, and supporting packages — written in Binate itself.

This repository is bootstrapped using the [Go bootstrap interpreter](https://github.com/binate/bootstrap), which runs the code here until the compiler can compile itself.

## Status

Self-hosted interpreter and compiler are working. The interpreter can interpret itself (double interpretation verified). The compiler produces native binaries via LLVM IR. Self-compilation works: gen1 (boot-comp-comp) and gen2 (boot-comp-comp-comp) compilers both pass all 98 conformance tests.

## Quick Start

Requires Go and the [bootstrap interpreter](https://github.com/binate/bootstrap):

```sh
# Clone both repos
git clone https://github.com/binate/bootstrap.git
git clone https://github.com/binate/binate.git

# Run a program via the self-hosted interpreter
cd bootstrap
go run . -root ../binate ../binate/cmd/bni -- ../binate/examples/selftest.bn

# Compile and run a program
go run . -root ../binate ../binate/cmd/bnc -- ../binate/examples/selftest.bn && ./selftest

# Run unit tests for a package
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/interp pkg/loader

# Run conformance tests
cd ../binate && ./conformance/run.sh boot
```

## Project Structure

```
binate/
  cmd/
    bni/                     Self-hosted interpreter (parse, load, interpret)
    bnc/                     Self-hosted compiler (parse, load, IR gen, LLVM emit)
  examples/
    selftest.bn              Quick smoke test (arithmetic, strings, loops, recursion)
  conformance/               Conformance test suite (shared across backends)
    run.sh                   Test runner (multiple modes)
    NNN_name.bn              Test programs
    NNN_name.expected        Expected stdout
  pkg/
    token/                   Token types, positions, keyword lookup
    ast/                     AST node types (Decl, Expr, Stmt, File)
    lexer/                   Tokenizer with automatic semicolon insertion
    parser/                  Recursive descent parser
    types/                   Type system and checker
    ir/                      IR generation (AST → SSA-like IR)
    codegen/                 LLVM IR emission
    interp/                  Tree-walking interpreter, values, environments
    loader/                  Package discovery, loading, merging, topological sort
    buf/                     CharBuf for string building
    debug/                   Verbose logging (SetVerbose, Log)
    rt/                      Runtime library (written in Binate)
    builtin/testing/         Test framework (TestResult type alias)
    bootstrap.bni            Interface for bootstrap-provided OS primitives
  runtime/
    binate_runtime.c         C runtime (memory management, slice ops)
```

## Architecture

### Execution Model

Programs run through three stages:

1. **Parse**: Source files are tokenized (lexer) and parsed (parser) into AST nodes.
2. **Load**: The package loader discovers imported packages on disk, parses their `.bn`/`.bni` files, merges multi-file packages, and computes a dependency-ordered load sequence via topological sort.
3. **Execute**: Either interpreted (tree-walking interpreter) or compiled (IR generation → LLVM IR → native binary via clang).

### Verbose Logging

All layers support `-v` for debug logging to stderr:

```sh
# Bootstrap verbose
go run . -v -root ../binate ../binate/cmd/bni -- program.bn

# Self-hosted interpreter verbose
go run . -root ../binate ../binate/cmd/bni -- -v program.bn

# Compiler verbose
go run . -root ../binate ../binate/cmd/bnc -- -v program.bn
```

### Double Interpretation

The self-hosted interpreter can interpret itself:

```
Go bootstrap
  → interprets cmd/bni (self-hosted interpreter)
    → interprets cmd/bni (self-hosted interpreter again)
      → interprets target.bn
```

This works because the bootstrap forwarding layer (`pkg/interp/bootstrap_fwd.bn`) bridges the gap: when interpreted code calls `bootstrap.Open()`, `bootstrap.Read()`, etc., the forwarding layer dispatches these to the real bootstrap functions provided by the Go runtime.

### Packages

Binate uses a filesystem-based package system. Each package has:

- **`.bni` file** (optional): Interface declarations (types, constants, function signatures without bodies). Located at `pkg/name.bni`.
- **`.bn` files**: Implementation files in a directory at `pkg/name/`. Multiple `.bn` files in the same directory are merged into one package.

```
myproject/
  cmd/myapp/
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
| `Exec`   | `(cmd []char, args [][]char) int` | Execute command, returns exit code |
| `Stat`   | `(path []char) int` | 0=not found, 1=file, 2=directory |
| `ReadDir`| `(path []char) [][]char` | Sorted directory entries |
| `Itoa`   | `(v int) []char` | Int to decimal string |
| `Concat` | `(a []char, b []char) []char` | String concatenation |

Constants: `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREATE`, `O_TRUNC`, `O_APPEND`, `STDIN`, `STDOUT`, `STDERR`.

## Testing

### Unit Tests

Each source file has a corresponding `*_test.bn` file with `func TestXxx() testing.TestResult` functions:

```sh
cd bootstrap
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/interp pkg/loader pkg/ir pkg/codegen

# Test main package directories
go run . -root ../binate -test ../binate/cmd/bni
go run . -root ../binate -test ../binate/cmd/bnc
```

Tests return `""` for pass, or a failure message string.

### Conformance Suite

Standalone `.bn` programs with expected output, shared across all execution backends:

```sh
cd binate
./conformance/run.sh boot               # Go bootstrap interpreter
./conformance/run.sh boot-int           # boot interprets cmd/bni → test.bn
./conformance/run.sh boot-int-int       # boot → cmd/bni → cmd/bni → test.bn
./conformance/run.sh boot-comp          # boot interprets cmd/bnc → compile test.bn
./conformance/run.sh boot-comp-int      # compiled interpreter binary → test.bn
./conformance/run.sh boot-comp-int-int  # compiled interp → cmd/bni → test.bn
./conformance/run.sh boot-comp-comp     # compiled compiler (gen1) → compile test.bn
./conformance/run.sh boot-comp-comp-comp  # gen2 compiler → compile test.bn
```

### Go-Level Tests

The bootstrap interpreter has its own Go test suite:

```sh
cd bootstrap
go test ./...
```

## Language

Binate is a systems programming language with dual-mode execution (compiled and interpreted), reference-counted memory management, and an embeddable interpreter. See the [explorations repo](https://github.com/binate/explorations) for language design documents.
