# bnfmt — Binate source formatter

Formats Binate source (`.bn` / `.bni`) files to a canonical form.

    bnfmt <file>              format to stdout (default; exactly one file)
    bnfmt -w <file>...        rewrite each file in place
    bnfmt --check <file>...   exit non-zero if any file is not already formatted
    bnfmt --version

Build with `scripts/build-bnfmt.sh -o <path>`.

## What it does

`bnfmt` parses the file (a `.bni` in interface mode, else ordinary mode) with
comment collection and re-prints it via `pkg/binate/format`: canonical
operator/comma spacing and indentation (tabs), sorted per-run imports, normalized
blank lines, single-line-vs-multi-line layout preserved from the source (with a
100-column force-expand), gofmt-style column alignment (struct field types,
single-line case bodies, grouped-decl trailing comments), and width-aware
fill-wrapping of argument / parameter / element / type-argument lists and binary
operator chains — all while preserving every comment. A line marked
`// LONG-LINE ALLOWED` is never reflowed.

The formatter is a fixpoint: `bnfmt` on already-formatted output is a no-op.

## Behavior

- **Multiple files:** `-w` and `--check` accept any number of files and process
  each independently (one file's parse error does not skip the rest); the default
  stdout mode takes exactly one file.
- **Parse errors:** on any syntax error `bnfmt` prints the diagnostics to stderr,
  exits non-zero, and leaves that file untouched (never a partial rewrite).
- **`--check`:** exits non-zero (without writing) iff any file is not already in
  canonical form, naming each unformatted file on stderr (`<path>: not formatted`).
- **`-w`:** crash-safe — writes to a temp file in the same directory and renames
  it over the original, so a crash mid-write leaves the original intact.
