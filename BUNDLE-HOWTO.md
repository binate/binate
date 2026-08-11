# Using a Binate toolchain bundle

A release bundle (e.g. `bnc-0.0.7`) is a self-contained toolchain: the four
binaries plus the standard library and runtime, with no Binate source checkout
required. It is the same artifact `BUILDER` is pinned to — see `BUILDER_VERSION`
and `scripts/fetch-builder.sh`, which downloads and verifies it.

## What's in a bundle

A bundle tarball `bnc-X.Y.Z-<os>-<arch>.tar.gz` extracts to a `bin/` + `lib/`
pair:

```
bin/
  bnc      compiler:    .bn → native executable (LLVM, or the native backend)
  bni      bytecode VM: runs .bn directly; also a REPL and a test runner
  bnas     assembler:   .s → .o
  bnlint   static analyzer: memory-safety lints
  bnfmt    formatter:   canonically re-prints .bn / .bni source (self-contained)
  binate-paths  prints the -I/-L/--runtime search paths for lib/ (see below)
lib/
  ifaces/core/      .bni for the builtins (pkg/builtins/*)
  ifaces/stdlib/    .bni for the stdlib    (pkg/std/*: strconv, errors, math/…)
  impls/core/       core impls: common, libc
  impls/stdlib/     stdlib implementations: common, libc
  runtime/          binate_runtime.c (+ baremetal_arm32/ for that target)
```

Put `bin/` on your `PATH`; everything else is reached through the search paths
below.

## The search paths (set these once)

Every tool resolves packages from interface directories (`-I`) and
implementation directories (`-L`); `bnc` also links a C runtime (`--runtime`).
The bundle ships `bin/binate-paths`, which emits all three for the bundle's
`lib/` — use it rather than spelling the paths out by hand:

```sh
# binate-paths self-locates the bundle's lib/ from its own bin/ location.
I="$(binate-paths --iface)"
L="$(binate-paths --impl)"
RT="$(binate-paths --runtime)"      # bnc only — linked into the executable
```

(`eval "$(binate-paths)"` instead sets `$BINATE_I` / `$BINATE_L` / `$BINATE_RT`
in one shot. Pass `--base /path/to/lib` if you invoke `binate-paths` from
outside the bundle.) It expands to the standard set — paths are colon-separated
and repeatable (cc-style), and the first `-I` entry doubles as the "source root":

```
-I  $LIB:$LIB/ifaces/core:$LIB/ifaces/stdlib
-L  $LIB:$LIB/impls/core/common:$LIB/impls/core/libc:$LIB/impls/stdlib
--runtime  $LIB/runtime/binate_runtime.c
```

What each entry covers:

- `ifaces/core` + `impls/core/*` — the builtins (`pkg/builtins/*`).
- `ifaces/stdlib` + `impls/stdlib` — the bundled stdlib
  (`pkg/std/strconv`, `pkg/std/errors`, …).
- `$LIB` (the bare root) — resolves nothing in a bundle (it's there for the
  source tree, where `pkg/binate/*` lives at the root); harmless to keep.

To build your **own** code, prepend your project root so your packages resolve
alongside the stdlib (the `$I`/`$L` above are bundle-only; prepend `$ROOT`
inline at each use, or regenerate them with `binate-paths --prepend "$ROOT"`):

```sh
ROOT=/path/to/my/project
bnc -I "$ROOT:$I" -L "$ROOT:$L" --runtime "$RT" -o app "$ROOT/cmd/app"
```

## bnc — compile

```sh
# A single file → ./hello
bnc -I "$I" -L "$L" --runtime "$RT" -o hello hello.bn

# A directory compiles every .bn in it (excluding *_test.bn)
bnc -I "$ROOT:$I" -L "$ROOT:$L" --runtime "$RT" -o app "$ROOT/cmd/app"
```

The bundled stdlib is used automatically once `ifaces/stdlib` +
`impls/stdlib` are on the paths — just import and call it:

```
package "main"

import "pkg/builtins/testing"
import "pkg/std/strconv"

func main() {
	var s @[]char = strconv.Itoa(4242)
	testing.Println(s[0:len(s)])
}
```

Useful flags:

| Flag | Effect |
|------|--------|
| `-o <name>`       | output name |
| `-c`              | emit `.o` only, don't link |
| `--emit-llvm`     | print LLVM IR to stdout (no executable) |
| `--build-dir <d>` | write intermediates under `<d>/` (must exist) instead of `/tmp` |
| `-g`              | emit DWARF debug info |
| `--target <key>`  | cross-target (e.g. `arm32-linux`); default is the host |
| `--test`          | build a unit-test binary (see below) |

> **Pass `--runtime` explicitly against a bundle.** bnc only auto-discovers
> `runtime/binate_runtime.c` relative to your source, not inside the bundle, so a
> bundle build must name it.

### Unit tests with bnc

`bnc --test` compiles the named test packages into a native test binary and
prints its path; run that binary to execute the tests:

```sh
bin=$(bnc --test -I "$ROOT:$I" -L "$ROOT:$L" --runtime "$RT" pkg/demo)
"$bin"      # === RUN … / --- PASS … / ok  1 passed
```

(For a quicker inline run that skips the native build, use `bni --test` below.)

## bni — interpret, test, REPL

bni runs `.bn` through the bytecode VM. No `--runtime` is needed — nothing is
linked.

```sh
# Run a program
bni -I "$I" -L "$L" hello.bn

# Run a package's tests inline (prints RUN/PASS directly)
bni -I "$ROOT:$I" -L "$ROOT:$L" --test pkg/demo

# REPL: a context file seeds the scope; expressions are read from stdin
bni -I "$I" -L "$L" --repl ctx.bn
```

`--test` also accepts `--run <substr>` and `--skip <substr>` name filters.

## bnlint — static analysis

bnlint flags memory-safety mistakes the type checker accepts (managed-to-raw
assignment, raw-slice return, unused imports). It takes package paths; the first
`-I` entry is the project root used to shorten reported paths:

```sh
bnlint -I "$ROOT:$I" -L "$ROOT:$L" pkg/demo pkg/other
```

Each finding is one line, `package:line:col: [rule] message`. Exit code is 1 if
any diagnostics are found, 0 otherwise.

## bnfmt — format

bnfmt canonically re-prints a `.bn` / `.bni` source file (spacing, sorted
imports, blank-line normalization, alignment, width-aware wrapping) while
preserving comments. It parses only syntax, so it needs no `-I`/`-L`/`lib/`:

```sh
bnfmt path/to/file.bn            # format to stdout (one file)
bnfmt -w file.bn ...             # rewrite each in place (crash-safe)
bnfmt --check file.bn ...        # exit non-zero if any is not already formatted
```

On a parse error bnfmt reports it to stderr and exits non-zero without writing.

## bnas — assemble

bnas assembles a `.s` file to an object file (aarch64 today):

```sh
bnas -arch aarch64 -o out.o in.s
```

With no `-o`, the output is the input with `.s` replaced by `.o`. The
architecture can also come from an `.arch` directive in the source. A minimal
program (sections via `.section`, exported symbols via `.global`):

```
.arch aarch64
.section text
.global _main
_main:
	mov w0, #42
	ret
```

```sh
bnas -arch aarch64 -o ret42.o ret42.s
cc -arch arm64 -o ret42 ret42.o -Wl,-e,_main   # custom entry; ./ret42 exits 42
```
