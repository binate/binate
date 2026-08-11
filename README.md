# Binate

[![Unit tests](https://github.com/binate/binate/actions/workflows/unit-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/unit-tests.yml)
[![Conformance tests](https://github.com/binate/binate/actions/workflows/conformance-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/conformance-tests.yml)
[![E2E tests](https://github.com/binate/binate/actions/workflows/e2e-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/e2e-tests.yml)
[![Code hygiene](https://github.com/binate/binate/actions/workflows/hygiene.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/hygiene.yml)
[![Perf tests](https://github.com/binate/binate/actions/workflows/perf-tests.yml/badge.svg)](https://github.com/binate/binate/actions/workflows/perf-tests.yml)

The self-hosted Binate toolchain — interpreter, compiler, and supporting packages — written in Binate itself.

Builds use a **prebuilt `bnc`** (the **BUILDER**) fetched by `scripts/fetch-builder.sh`. The version is pinned in the `BUILDER_VERSION` file at the repo root (currently `bnc-0.0.12`). See [BUILDER_VERSION](#builder_version) and [Releases](#releases) below.

## Status

The self-hosted interpreter and compiler are working. The interpreter can interpret itself (double interpretation verified). The compiler produces native binaries via LLVM IR. Self-compilation works: gen1 (`builder-comp-comp`) and gen2 (`builder-comp-comp-comp`) compilers both pass the conformance suite.

## Quick Start

```sh
# Clone
git clone https://github.com/binate/binate.git
cd binate

# Resolve the BUILDER (downloads the pinned bnc release on first run,
# caches under ~/.cache/binate/builders/<version>/).
BUILDER="$(scripts/fetch-builder.sh)"

# Compile and run a program via the BUILDER directly.
"$BUILDER" -o /tmp/selftest examples/selftest.bn && /tmp/selftest

# Or: build a current-tree bnc and use that.
./scripts/build-bnc.sh -o /tmp/bnc
/tmp/bnc -o /tmp/selftest examples/selftest.bn

# Build the self-hosted bytecode VM (bni) and run a program through it.
./scripts/build-bni.sh -o /tmp/bni
/tmp/bni examples/selftest.bn

# Run unit tests for some packages.
./scripts/unittest/run.sh builder-comp pkg/binate/types pkg/binate/loader

# Run conformance tests.
./conformance/run.sh builder-comp
```

Requires `clang` on `PATH` (used as the final linker for compiled output).

### BUILDER_VERSION

The `BUILDER_VERSION` file at the repo root names the compiler used to build the current tree's compiler. Two schemes are recognized by `scripts/fetch-builder.sh`:

- **`bnc-X.Y.Z`** (the only supported scheme; current pin: `bnc-0.0.12`): downloaded from a published GitHub release as a tarball containing `bnc`, `bni`, `bnas`, `bnlint`, and a `lib/` stdlib root. Cached under `~/.cache/binate/builders/<version>/`. No source build needed.
- **`bootstrap-X.Y.Z`** (RETIRED): formerly built the sibling [`bootstrap/`](https://github.com/binate/bootstrap) Go interpreter and used it as the BUILDER. That scheme is gone — `fetch-builder.sh` now ERRORS on any `bootstrap-*` value; every build bootstraps from a published `bnc-X.Y.Z` release instead. See [explorations/plan-bnc-as-builder.md](https://github.com/binate/explorations/blob/main/plan-bnc-as-builder.md).

All test runners and `scripts/build-*.sh` helpers go through `fetch-builder.sh`; you don't normally invoke it directly outside the Quick Start example.

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
BUILDER="$(scripts/fetch-builder.sh)"

# Compiler verbose
"$BUILDER" -v -o /tmp/prog program.bn

# Self-hosted interpreter verbose
./scripts/build-bni.sh -o /tmp/bni
/tmp/bni -v program.bn
```

### Double Interpretation

The self-hosted interpreter can interpret itself:

```
bni (built via the BUILDER)
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
import "pkg/builtins/testing"

func main() {
    testing.Println(math.Add(2, 3))
}
```

## Testing

### Unit Tests

Each source file has a corresponding `*_test.bn` file with `func TestXxx() testing.TestResult` functions. The recommended entry point is `scripts/unittest/run.sh`, which uses the BUILDER to compile the current-tree `cmd/bnc` and then runs each test package through the selected mode:

```sh
# Run all unit tests through current-tree cmd/bnc.
./scripts/unittest/run.sh builder-comp

# Filter to specific packages.
./scripts/unittest/run.sh builder-comp pkg/binate/types

# pkg/binate/vm and cmd/bni need bni (the bytecode VM); use a *-int mode.
./scripts/unittest/run.sh builder-comp-int pkg/binate/vm cmd/bni
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

The sibling [`bootstrap/`](https://github.com/binate/bootstrap) Go interpreter — retired as a BUILDER (see [BUILDER_VERSION](#builder_version) above) — still has its own Go test suite (`go test ./...` in that repo), but it is no longer part of building or testing the toolchain.

## Releases

Releases are tagged `bnc-X.Y.Z` and built by `.github/workflows/release.yml`:

1. A tag push (`bnc-X.Y.Z`) triggers the workflow.
2. For each release platform, the BUILDER (from the current `BUILDER_VERSION`) compiles `cmd/bnc`, `cmd/bni`, `cmd/bnas`, `cmd/bnlint` against the tagged source. The resulting binaries plus a `lib/` stdlib root are packaged as a tarball.
3. The release publishes the tarballs and a `SHA256SUMS` manifest.
4. Cutting the next release usually means bumping `BUILDER_VERSION` to the just-published `bnc-X.Y.Z` and tagging again.

`scripts/fetch-builder.sh` downloads release tarballs into `~/.cache/binate/builders/`.

## Language

Binate is a systems programming language with dual-mode execution (compiled and interpreted), reference-counted memory management, and an embeddable interpreter. See the [explorations repo](https://github.com/binate/explorations) for language design documents.

## License

[MIT](LICENSE)
