# bnlint

Static analysis tool for Binate source code. Catches common memory safety
mistakes that the type checker accepts but lead to runtime bugs.

## Usage

```
bnlint --root <project-dir> <pkg1> [pkg2 ...]
```

Run via the bootstrap interpreter:

```
go run . -root <binate-src> cmd/bnlint -- --root <binate-src> pkg/foo pkg/bar
```

Or via the self-hosted interpreter:

```
binate -root <binate-src> cmd/bnlint -- --root <binate-src> pkg/foo
```

## Flags

- `--root <dir>` — Project root directory (required). Used to resolve package
  paths and locate `.bni` interface files.

## Output

One line per diagnostic:

```
pkg/types:17:29: [managed-to-raw-assign] assigning @[]uint8 to []uint8 drops managed wrapper
pkg/codegen:41:19: [raw-slice-return] returning @[]uint8 as []uint8 drops managed wrapper
```

Format: `package:line:col: [rule] message`

Exit code 0 if no diagnostics, 1 if any are found (or on error).

## Rules

### managed-to-raw-assign

Flags assignments where the right-hand side is `@[]T` (managed-slice) but the
left-hand side is `[]T` (raw slice). This silently drops the managed wrapper —
if the `@[]T` was a temporary (e.g., a function return value), the raw slice
is immediately dangling.

Checked in:
- Variable declarations: `var s []T = managedSliceExpr`
- Assignments: `s = managedSliceExpr`

### raw-slice-return

Flags return statements where the function declares a `[]T` return type but
the returned expression has type `@[]T`. The managed wrapper is stripped at the
return boundary, and the caller receives a raw slice whose backing may be freed.

## Examples

Lint a single package:

```
go run . -root ~/binate/binate cmd/bnlint -- --root ~/binate/binate pkg/ir
```

Lint multiple packages:

```
go run . -root ~/binate/binate cmd/bnlint -- --root ~/binate/binate pkg/ir pkg/types pkg/codegen
```

## Running Tests

```
go run . -test -root <binate-src> cmd/bnlint
```
