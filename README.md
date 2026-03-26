# Binate

The self-hosted Binate toolchain — interpreter, compiler, and supporting tools — written in Binate itself.

This is the main repository for the Binate programming language. It is bootstrapped using the [Go bootstrap interpreter](https://github.com/binate/bootstrap), which runs the code in this repo until the compiler can compile itself.

## Status

Early development. Building the self-hosted interpreter (Phase 5a).

## Building & Running

Requires the [bootstrap interpreter](https://github.com/binate/bootstrap):

```sh
cd /path/to/bootstrap
go run main.go -root /path/to/binate main.bn
```

## Project Structure

```
binate/
  main.bn                    entry point
  pkg/
    token/                    token types and positions
    ast/                      AST node types
    lexer/                    tokenizer with semicolon insertion
    parser/                   recursive descent parser
    types/                    type system and checker
    interp/                   tree-walking interpreter
```

## Language

Binate is a systems programming language with dual-mode execution (compiled and interpreted), reference-counted memory management, and an embeddable interpreter. See the [explorations repo](https://github.com/binate/explorations) for the language design.
