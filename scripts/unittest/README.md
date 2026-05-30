# Unit Test Runner

Runs unit tests for all Binate packages across multiple execution backends.

## Running

```sh
./scripts/unittest/run.sh [-v|-q] <mode> [filter...]
```

Flags: `-v` (verbose — show all package results), `-q` (quiet — failures and summary only), default (dots for passes, detail for failures).

Run `./scripts/unittest/run.sh` with no arguments for full help.

### Quick examples

```sh
./scripts/unittest/run.sh builder-comp                Run all packages via the builder
./scripts/unittest/run.sh builder-comp vm             pkg/vm via the builder
./scripts/unittest/run.sh basic                    builder-comp + builder-comp-int
./scripts/unittest/run.sh builder-comp ir codegen     pkg/binate/ir and pkg/codegen
```

### Modes

Each mode is a chain of: `builder` (resolved BUILDER_VERSION binary), `comp` (compiler from current tree), `int` (bytecode VM).

| Mode | Description |
|------|-------------|
| `builder-comp` | Builder interprets cmd/bnc → compiles and runs tests |
| `builder-comp-int` | Compiled cmd/bni runs `--test` natively via bytecode VM |
| `builder-comp-comp` | Gen1 compiler compiles and runs tests |
| `builder-comp-comp-int` | Gen1-compiled cmd/bni runs `--test` natively via bytecode VM |
| `builder-comp-comp-comp` | Gen2 compiler compiles and runs tests |

Mode sets are defined in `scripts/modesets/` (one file per set, one mode per line). Adding a new mode set is just adding a file. Current sets: `basic`, `all`.

### Filters

Optional arguments filter packages by substring match (e.g. `ir` matches `pkg/binate/ir`). Multiple filters are OR'd.

## Test Convention

- Test files: `*_test.bn` in the package directory
- Test functions: `func TestXxx() testing.TestResult`
- Return `""` for pass, non-empty string for failure message
- Must `import "pkg/builtins/testing"` for the `TestResult` type
- Test files are excluded from normal builds

## Expected Failures (xfail)

`scripts/unittest/<pkg-path>.xfail.<mode>` marks a package as expected failure for that mode. Slashes in the package path are replaced with dashes.

Example: `scripts/unittest/pkg-vm.xfail.builder-comp-comp-int` with contents describing the reason.

## Package Discovery

The runner automatically discovers all packages with `*_test.bn` files under `pkg/` and `cmd/`. No manual registration needed.
