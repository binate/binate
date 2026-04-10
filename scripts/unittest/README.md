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
./scripts/unittest/run.sh boot              # All packages via bootstrap
./scripts/unittest/run.sh boot-comp interp  # pkg/interp via compiler
./scripts/unittest/run.sh basic             # boot + boot-comp + boot-comp-int
./scripts/unittest/run.sh boot ir codegen   # pkg/ir and pkg/codegen
```

### Modes

| Mode | Description |
|------|-------------|
| `boot` | Go bootstrap interpreter runs `-test` directly |
| `boot-comp` | Bootstrap interprets cmd/bnc → compiles and runs tests |
| `boot-comp-int` | Compiled cmd/bni runs `--test` natively |
| `boot-comp-comp` | Gen1 compiler compiles and runs tests |
| `boot-comp-comp-comp` | Gen2 compiler compiles and runs tests |

Mode sets: `basic` (boot, boot-comp, boot-comp-int), `all` (basic + boot-comp-comp), `full` (all + boot-comp-comp-comp).

### Filters

Optional arguments filter packages by substring match (e.g. `ir` matches `pkg/ir`). Multiple filters are OR'd.

## Test Convention

- Test files: `*_test.bn` in the package directory
- Test functions: `func TestXxx() testing.TestResult`
- Return `""` for pass, non-empty string for failure message
- Must `import "pkg/builtin/testing"` for the `TestResult` type
- Test files are excluded from normal builds

## Expected Failures (xfail)

`scripts/unittest/<pkg-path>.xfail.<mode>` marks a package as expected failure for that mode. Slashes in the package path are replaced with dashes.

Example: `scripts/unittest/pkg-rt.xfail.boot` with contents `bootstrap does not support raw memory operations`.

## Package Discovery

The runner automatically discovers all packages with `*_test.bn` files under `pkg/` and `cmd/`. No manual registration needed.
