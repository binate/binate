# bnfmt — Binate source formatter

Formats Binate source (`.bn` / `.bni`) files.

    bnfmt <file>            format to stdout (default)
    bnfmt -w <file>         rewrite the file in place
    bnfmt --check <file>    exit non-zero if the file is not already formatted
    bnfmt --version

Build with `scripts/build-bnfmt.sh -o <path>`.

**Status:** scaffolding. Formatting is not yet implemented — `formatSource` is
currently the identity, so bnfmt round-trips a file byte-for-byte. This step
wires up the build, the CLI, and the I/O modes; the AST-driven printer, comment
attachment, alignment, and line-wrapping land in subsequent steps. See
`explorations/plan-bnfmt.md`.

Known follow-up: `-w` is a direct (non-atomic) truncate+write, which is safe
only while output equals input; before formatting output can diverge it must
become crash-safe (temp file + rename), which needs an `os.Rename` (absent from
the stdlib today).
