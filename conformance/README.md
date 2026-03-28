# Conformance Tests

End-to-end tests that verify language behavior across all execution backends.

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
| `compiled-compiler` | Self-compiled compiler binary compiles test to native |
| `compiled-interp` | Self-compiled interpreter binary runs test |

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

### Environment Variables

| Variable | Description |
|----------|-------------|
| `BINATE_FLAGS` | Extra flags passed to the Binate compiler (e.g. `-g` for debug info) |

```sh
# Run compiled tests with debug info enabled
BINATE_FLAGS="-g" ./conformance/run.sh compiled
```

### Expected Failures

A test can be marked as a known failure for a specific mode by creating a file `NNN_name.xfail.<mode>` containing a one-line explanation. Known failures show as `XFAIL` instead of `FAIL` and don't count as failures.

## Adding Tests

1. Create `NNN_name.bn` with a `main()` that prints expected output via `println`.
2. Create `NNN_name.expected` with the exact expected stdout (include trailing newline).
3. For multi-package tests, create a `NNN_name/` directory with `main.bn`, `expected`, and a `pkg/` subdirectory.
4. Run against all modes to verify.
