# Conformance Tests

End-to-end tests that verify language behavior across all three execution backends.

## Usage

```sh
./conformance/run.sh <mode> [filter...]
```

### Modes

| Mode | Description |
|------|-------------|
| `bootstrap` | Run via the Go bootstrap interpreter |
| `selfhost` | Run via the self-hosted interpreter (main.bn on bootstrap) |
| `compiled` | Compile to LLVM IR, build with clang, run the binary |

### Filters

Optional arguments filter tests by substring match against the test name. Multiple filters are OR'd.

```sh
# Run all tests
./conformance/run.sh compiled

# Run a single test by number
./conformance/run.sh compiled 040

# Run tests matching any of several patterns
./conformance/run.sh compiled recursive int_lit switch
```

## Adding Tests

1. Create `NNN_name.bn` with a `main()` that prints expected output via `println`.
2. Create `NNN_name.expected` with the exact expected stdout (include trailing newline).
3. Run against all three modes to verify.
