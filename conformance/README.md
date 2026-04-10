# Conformance Tests

Standalone `.bn` programs with expected output, shared across all execution backends.

## Running

```sh
./conformance/run.sh <mode> [filter...]
```

Run `./conformance/run.sh` with no arguments for full help.

### Quick examples

```sh
./conformance/run.sh boot              # All tests via bootstrap interpreter
./conformance/run.sh boot-comp         # All tests via compiler
./conformance/run.sh boot-comp 040     # Test(s) matching '040'
./conformance/run.sh basic             # boot + boot-comp + boot-comp-int
./conformance/run.sh boot slice nil    # Tests matching 'slice' or 'nil'
```

### Modes

Each mode is a chain of: `boot` (bootstrap interpreter), `comp` (compiler), `int` (interpreter).

| Mode | Description |
|------|-------------|
| `boot` | Go bootstrap interpreter runs .bn directly |
| `boot-comp` | Bootstrap interprets cmd/bnc → compiles test to native |
| `boot-comp-int` | Compiled cmd/bni interprets test |
| `boot-comp-comp` | Gen1 compiler compiles test |
| `boot-comp-comp-comp` | Gen2 compiler compiles test |

Mode sets: `basic` (boot, boot-comp, boot-comp-int), `all` (all modes).

### Filters

Optional arguments filter tests by substring match against the test name. Multiple filters are OR'd.

```sh
./conformance/run.sh boot-comp recursive int_lit switch
```

## Test Formats

### Positive tests

`NNN_name.bn` + `NNN_name.expected`: run the program, compare stdout to expected output.

### Negative tests (error tests)

`NNN_name.bn` + `NNN_name.error`: the program must fail to compile/run. Each line in the `.error` file is a `grep -E` regex pattern that must appear in the error output.

### Multi-package tests

`NNN_name/` directory containing `main.bn`, `expected`, and a `pkg/` subdirectory with the test's packages.

## Expected Failures (xfail)

`NNN_name.xfail.<mode>` marks a test as expected failure for that mode. The file contents describe the reason. Known failures show as `XFAIL` instead of `FAIL` and don't count as failures in the summary.

Example: `042_foo.xfail.boot` with contents `requires bit_cast (compiled mode only)`.

## Environment

| Variable | Description |
|----------|-------------|
| `BINATE_FLAGS` | Extra flags passed to the compiler (e.g. `-g` for debug info) |

## Adding a Test

1. Create `NNN_name.bn` with `package "main"` and `func main()` that prints expected output
2. Create `NNN_name.expected` with the exact expected stdout (include trailing newline)
3. For negative tests, create `NNN_name.error` instead with `grep -E` regex patterns
4. For multi-package tests, create `NNN_name/` with `main.bn`, `expected`, and `pkg/`
5. Add `.xfail.<mode>` files for any modes where the test is expected to fail
6. Run against all modes: `./conformance/run.sh basic`
