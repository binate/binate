# bnlint

Static analysis tool for Binate source code. Catches common memory safety
mistakes that the type checker accepts but lead to runtime bugs.

## Usage

```
bnlint -I <project-dir> [-L <project-dir>] <pkg1> [pkg2 ...]
```

The first `-I` entry doubles as the project root (used to strip path
prefixes from diagnostic file paths).  `-L` mirrors the `-I` list when
the impl tree lives next to the .bni tree (typical for an in-tree
checkout); see `e2e/split-paths.sh` for the split-tree shape.

Run via the bootstrap interpreter:

```
go run . -root <binate-src> cmd/bnlint -- -I <binate-src> -L <binate-src> pkg/foo pkg/bar
```

Or via the self-hosted interpreter:

```
binate -I <binate-src> -L <binate-src> cmd/bnlint -- -I <binate-src> -L <binate-src> pkg/foo
```

## Flags

- `-I <dirs>` / `--interface-path <dirs>` — Colon-separated dirs searched for
  `.bni` files.  Repeatable; the first entry seeds the source root.  Required.
- `-L <dirs>` / `--impl-path <dirs>` — Colon-separated dirs searched for impl
  directories.  Repeatable.

## Output

One line per diagnostic:

```
pkg/binate/types:17:29: [managed-to-raw-assign] assigning @[]uint8 to *[]uint8 drops managed wrapper
pkg/codegen:41:19: [raw-slice-return] returning @[]uint8 as *[]uint8 drops managed wrapper
```

Format: `package:line:col: [rule] message`

Exit code 0 if no diagnostics, 1 if any are found (or on error).

## Rules

### managed-to-raw-assign

Flags assignments where the right-hand side is `@[]T` (managed-slice) but the
left-hand side is `*[]T` (raw slice). This silently drops the managed wrapper —
if the `@[]T` was a temporary (e.g., a function return value), the raw slice
is immediately dangling.

Checked in:
- Variable declarations: `var s *[]T = managedSliceExpr`
- Assignments: `s = managedSliceExpr`

### raw-slice-return

Flags return statements where the function declares a `*[]T` return type but
the returned expression has type `@[]T`. The managed wrapper is stripped at the
return boundary, and the caller receives a raw slice whose backing may be freed.

### unused-import

Flags an import whose package name is never referenced in the file that
declared it (Go-style, per-file). A reference is any `pkg.X` expression or
`pkg.T` type qualified by the import's local name (its alias, or the path's
last segment when there's no alias).

Blank imports (`import _ "pkg/foo"`) are intentional side-effect imports and
are never flagged.

Because a package is linted as its merged AST and imports are deduplicated by
(alias, path) at merge time, a path imported-and-unused in one file but
imported-and-used in another is not flagged — a rare, safe under-warning.

## Examples

Lint a single package:

```
go run . -root ~/binate/binate cmd/bnlint -- -I ~/binate/binate -L ~/binate/binate pkg/ir
```

Lint multiple packages:

```
go run . -root ~/binate/binate cmd/bnlint -- -I ~/binate/binate -L ~/binate/binate pkg/ir pkg/binate/types pkg/codegen
```

## Running Tests

```
go run . -test -root <binate-src> cmd/bnlint
```
