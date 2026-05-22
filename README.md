# Binate

[![Unit tests](https://github.com/binate/binate/actions/workflows/unit-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/unit-tests.yml)
[![Conformance tests](https://github.com/binate/binate/actions/workflows/conformance-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/conformance-tests.yml)
[![E2E tests](https://github.com/binate/binate/actions/workflows/e2e-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/e2e-tests.yml)
[![Code hygiene](https://github.com/binate/binate/actions/workflows/hygiene.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/hygiene.yml)
[![Perf tests](https://github.com/binate/binate/actions/workflows/perf-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/perf-tests.yml)

The self-hosted Binate toolchain — interpreter, compiler, and supporting packages — written in Binate itself.

This repository is bootstrapped using the [Go bootstrap interpreter](https://github.com/binate/bootstrap), which runs the code here until the compiler can compile itself.

## Status

Self-hosted interpreter and compiler are working. The interpreter can interpret itself (double interpretation verified). The compiler produces native binaries via LLVM IR. Self-compilation works: gen1 (builder-comp-comp) and gen2 (builder-comp-comp-comp) compilers both pass all 98 conformance tests.

## Quick Start

Requires Go and the [bootstrap interpreter](https://github.com/binate/bootstrap):

```sh
# Clone both repos
git clone https://github.com/binate/bootstrap.git
git clone https://github.com/binate/binate.git
cd binate

# Compile and run a program via bnc-via-bootstrap
cd ../bootstrap
go run . -root ../binate ../binate/cmd/bnc -- -o /tmp/selftest ../binate/examples/selftest.bn && /tmp/selftest

# Build the self-hosted interpreter (bni) and run a program through it
cd ../binate
./scripts/build-bni.sh -o /tmp/bni
/tmp/bni examples/selftest.bn

# Run unit tests for some bootstrap-runnable packages
cd ../bootstrap
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/loader

# Run conformance tests
cd ../binate && ./conformance/run.sh builder-comp
```

### What the bootstrap can and can't run

The Go bootstrap interpreter implements only a subset of the Binate language —
no floats, no raw memory ops, no method dispatch via interface, etc.  That's
enough to interpret `cmd/bnc` (the compiler) and the packages it depends on,
but *not* the bytecode VM (`pkg/vm`, `cmd/bni`).  Practical consequence:

- **Always bootstrap-runnable:** `cmd/bnc` and its dependency tree
  (`pkg/{token,lexer,ast,parser,types,ir,codegen,loader,buf,debug,mangle,builtin/testing,bootstrap,rt}`),
  plus `cmd/bnas` and `cmd/bnlint`.
- **Needs bnc to build first:** `cmd/bni`, `pkg/vm`.  Use
  `scripts/build-bni.sh -o <path>` (or the test runners' `builder-comp*` modes)
  rather than `go run . -test pkg/vm` / `go run . cmd/bni`.

See [explorations/bootstrap-subset.md](https://github.com/binate/explorations/blob/main/bootstrap-subset.md)
for the language subset.  The CI test runners pin BUILDER_VERSION to
the bnc release the current tree was built from (or
`bootstrap-X.Y.Z` while bnc is still pre-1.0); each test mode goes
through `scripts/fetch-builder.sh` to resolve it.

## Project Structure

```
binate/
  cmd/
    bni/                    Self-hosted interpreter (bytecode VM)
    bnc/                     Self-hosted compiler (parse, load, IR gen, LLVM emit)
    bnas/                    Assembler
    bnlint/                  Linter
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
    vm/                      Bytecode VM used by cmd/bni
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
3. **Execute**: Either interpreted (bytecode VM) or compiled (IR generation → LLVM IR → native binary via clang).

### Verbose Logging

All layers support `-v` for debug logging to stderr:

```sh
# Bootstrap verbose (driving the compiler)
go run . -v -root ../binate ../binate/cmd/bnc -- program.bn

# Compiler verbose
go run . -root ../binate ../binate/cmd/bnc -- -v program.bn

# Self-hosted interpreter verbose (built bni binary)
./scripts/build-bni.sh -o /tmp/bni
/tmp/bni -v program.bn
```

### Double Interpretation

The self-hosted interpreter can interpret itself.  The bootstrap can't run
cmd/bni directly, so the outermost driver is a compiled bni:

```
compiled bni (built via bnc-via-bootstrap)
  → interprets cmd/bni (self-hosted interpreter)
    → interprets target.bn
```

This is the `builder-comp-int-int` mode in the test harness.

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
| `Open`   | `(path *[]char, flags int) int` | Open file, returns fd |
| `Read`   | `(fd int, buf *[]uint8, n int) int` | Read bytes into buffer |
| `Write`  | `(fd int, buf *[]uint8, n int) int` | Write bytes from buffer |
| `Close`  | `(fd int) int` | Close file descriptor |
| `Exit`   | `(code int)` | Exit process |
| `Args`   | `() *[]*[]char` | Program arguments (after `--`) |
| `Exec`   | `(cmd *[]char, args *[]*[]char) int` | Execute command, returns exit code |
| `Stat`   | `(path *[]char) int` | 0=not found, 1=file, 2=directory |
| `ReadDir`| `(path *[]char) *[]*[]char` | Sorted directory entries |
| `Itoa`   | `(v int) *[]char` | Int to decimal string |
| `Concat` | `(a *[]char, b *[]char) *[]char` | String concatenation |

Constants: `O_RDONLY`, `O_WRONLY`, `O_RDWR`, `O_CREATE`, `O_TRUNC`, `O_APPEND`, `STDIN`, `STDOUT`, `STDERR`.

## Testing

### Unit Tests

Each source file has a corresponding `*_test.bn` file with `func TestXxx() testing.TestResult` functions.  The recommended entry point is `scripts/unittest/run.sh`, which knows which packages can run under which modes (see the [Quick Start](#what-the-bootstrap-can-and-cant-run) note):

```sh
# Run all unit tests through current-tree cmd/bnc — the BUILDER
# compiles cmd/bnc once, then that compiles + runs each test
# package.
./scripts/unittest/run.sh builder-comp

# Filter to specific packages.
./scripts/unittest/run.sh builder-comp pkg/types

# pkg/vm and cmd/bni use a compiled bni; use a *-int mode.
./scripts/unittest/run.sh builder-comp-int pkg/vm cmd/bni
```

For ad-hoc bootstrap-direct invocations (skipping the runner), invoke the bootstrap interpreter manually but only on bootstrap-runnable packages:

```sh
cd bootstrap
go run . -root ../binate -test pkg/token pkg/lexer pkg/types pkg/loader pkg/ir pkg/codegen
```

Tests return `""` for pass, or a failure message string.

### Conformance Suite

Standalone `.bn` programs with expected output, shared across all execution backends:

```sh
cd binate
./conformance/run.sh builder-comp              # current-tree cmd/bnc compiles test.bn → native
./conformance/run.sh builder-comp-int          # compiled bni (bytecode VM) → test.bn
./conformance/run.sh builder-comp-int-int      # compiled bni → cmd/bni → test.bn
./conformance/run.sh builder-comp-comp         # gen1 compiles gen2; gen2 compiles test.bn
./conformance/run.sh builder-comp-comp-int     # gen1-compiled bni → test.bn
./conformance/run.sh builder-comp-comp-comp    # ... gen3 compiles test.bn (self-host check)
```

### Go-Level Tests

The bootstrap interpreter has its own Go test suite:

```sh
cd bootstrap
go test ./...
```

## Language

Binate is a systems programming language with dual-mode execution (compiled and interpreted), reference-counted memory management, and an embeddable interpreter. See the [explorations repo](https://github.com/binate/explorations) for language design documents.

## License

[MIT](LICENSE)
