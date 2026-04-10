# bnas

Binate assembler. Assembles `.s` files into object files.

## Usage

```
bnas [-o output.o] [-arch aarch64] input.s
```

If `-o` is not specified, the output file is the input filename with `.s` replaced by `.o`.

## Flags

| Flag | Description |
|------|-------------|
| `-o <file>` | Output object file path |
| `-arch <name>` | Target architecture (`aarch64` or `arm64`) |

The architecture can also be set via an `.arch` directive in the assembly source file.

## Example

```sh
bnas -arch aarch64 -o hello.o hello.s
```
