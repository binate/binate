#!/usr/bin/env python3
"""Generate conformance/matrix/globals cells — package-level global/static
storage materialization across type shapes.

The defect class: the global-emission paths (codegen static-zero token dispatch,
struct-type discovery, VM data lowering) enumerate type kinds by hand and never
peel transparent wrappers (TYP_NAMED) nor scan m.Globals, so every off-default
type-shape in GLOBAL position is an empty cell the local/param/return positions
never exercise. The default coordinate (plain int / direct value) works; the
named-over-aggregate / managed / readonly shapes break specifically in global
position.

Assertion: the module COMPILES (no clang 'integer constant must have integer
type' / 'use of undefined type') and the global reads back its initialized value
(or the zero value for no-init). Each cell prints one int per lane. Runs on all
modes incl. native + VM (the VM materializes globals via a separate data path
that must agree).

Coordinate-addressed: matrix/globals/<storage>/<type>.bn (+ .expected). Path =
identity; regeneration idempotent; never touches .xfail.<mode>.
Run: python3 conformance/gen-globals-matrix.py [--check].
"""

import os
import sys

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "matrix", "globals")

# Shared helper fragments.
STRUCT_S = "type S struct {\n\ta int\n\tb int\n}"
IFACE_G = ("interface Getter {\n\tget() int\n}\n\n"
           "type Impl struct {\n\tv int\n}\n\n"
           "func (im *Impl) get() int {\n\treturn im.v\n}\n\n"
           "impl *Impl : Getter")
BOX = "type Box struct {\n\tv int\n}"

# Each cell: (relpath, helpers, gdecl, reads[list of exprs], expected[list]).
# `reads` are expressions printed via println; an expr already an int prints
# directly, else it's cast to int by _emit.
CELLS = [
    # --- init: value types, assert the materialized VALUE (controls) ---
    ("init/int", "", "var G int = 42", ["G"], [42]),
    ("init/uint16", "", "var G uint16 = 600", ["cast(int, G)"], [600]),
    ("init/int8", "", "var G int8 = -5", ["cast(int, G)"], [-5]),
    ("init/bool", "", "var G bool = true", ["cast(int, G)"], [1]),
    ("init/float64", "", "var G float64 = 3.5", ["cast(int, G * 2.0)"], [7]),
    ("init/float32", "", "var G float32 = 2.5", ["cast(int, G * 2.0)"], [5]),
    ("init/struct", STRUCT_S, "var G S = S{10, 20}", ["G.a", "G.b"], [10, 20]),
    ("init/array", "", "var G [3]int = [3]int{10, 20, 30}", ["G[0]", "G[2]"], [10, 30]),
    # Named-distinct fixed-array global. The initializer uses the unnamed
    # `[3]int{...}` literal (which the unnamed→named array assignability of
    # named-distinct transparency accepts) rather than `Row{...}`: a composite
    # literal written with a NAMED type name (`Row{...}`) is silently
    # miscompiled to a const-0 — genCompositeLit dispatches on TypeRef.Kind and
    # never peels TYP_NAMED, so it drops the initializer (filed in claude-todo).
    ("init/named-array", "type Row [3]int", "var G Row = [3]int{10, 20, 30}", ["G[0]", "G[2]"], [10, 30]),
    ("init/named-scalar", "type Count int", "var G Count = 42", ["cast(int, G)"], [42]),
    ("init/named-float", "type Temp float64", "var G Temp = 2.5", ["cast(int, G * 2.0)"], [5]),

    # --- noinit: zero value, assert zero / compile (controls) ---
    ("noinit/int", "", "var G int", ["G"], [0]),
    ("noinit/struct", STRUCT_S, "var G S", ["G.a", "G.b"], [0, 0]),
    ("noinit/array", "", "var G [3]int", ["G[0]", "G[2]"], [0, 0]),
    # Named-distinct fixed-array, no init: index + len peel TYP_NAMED
    # (named-distinct transparency), so element 0 is the zero value and
    # len is the static array length.
    ("noinit/named-array", "type Row [3]int", "var G Row", ["G[0]", "cast(int, len(G))"], [0, 3]),
    ("noinit/nested-array", "", "var G [2][2]int", ["G[1][0]"], [0]),
    ("noinit/managed-slice", "", "var G @[]int", ["cast(int, len(G))"], [0]),
    ("noinit/iface", IFACE_G, "var G @Getter", ["cast(int, present(G))"], [0]),
    ("noinit/func", "", "var G @func() int", ["0"], [0]),
    ("noinit/managed-ptr", BOX, "var G @Box", ["0"], [0]),

    # --- noinit named-over-NON-struct wrappers: the named-peel zero-token bug
    #     (named struct is TYP_STRUCT, not a TYP_NAMED wrapper — so it is a
    #     CONTROL; the wrapper bug is over managed-slice / managed-ptr / iface /
    #     func, where the dispatch's missing TYP_NAMED peel emits an invalid zero
    #     token against a struct/pointer LLVM type). These are COMPILE assertions
    #     (read `0`): a green cell compiles, a red one fails at the global emit. ---
    ("noinit/named-scalar0", "type Count int", "var G Count", ["cast(int, G)"], [0]),
    # Named-distinct managed-slice, no init: `len` peels TYP_NAMED
    # (named-distinct transparency), so a nil slice reads len 0 — mirrors
    # the non-named noinit/managed-slice cell.
    ("noinit/named-managed-slice", "type Buf @[]int", "var G Buf", ["cast(int, len(G))"], [0]),
    ("noinit/named-managed-ptr", BOX + "\n\ntype P @Box", "var G P", ["0"], [0]),
    ("noinit/named-iface", IFACE_G + "\n\ntype H @Getter", "var G H", ["0"], [0]),
    ("noinit/named-func", "type Fn @func() int", "var G Fn", ["0"], [0]),
    # named-distinct OVER a struct (TYP_NAMED → TYP_STRUCT — NOT a plain named
    # struct, which is TYP_STRUCT directly). The one cell exercising BOTH codegen
    # global fixes at once: discoverStructFromType's TYP_NAMED arm must reach the
    # underlying struct through the global (no function references it) so
    # `%bn_S...` is declared, AND the static-zero dispatch must peel TYP_NAMED
    # so the `%bn_S...` slot gets `zeroinitializer`, not the invalid ` 0`.
    # Compile assertion (read `0`): field access on a named-distinct VALUE is a
    # separate unratified spec question (claude-todo), so main does not read G's
    # fields — which also keeps the struct reachable ONLY via the global, the
    # condition that isolates the discovery path.
    ("noinit/named-struct", STRUCT_S + "\n\ntype NS S", "var G NS", ["0"], [0]),

    # --- readonly global (overlaps Class B readonly field-read) ---
    ("readonly/struct", STRUCT_S, "var G readonly S = S{10, 20}", ["G.a", "G.b"], [10, 20]),
]

HEADER = """package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-globals-matrix.py — do not edit by hand.
// globals matrix cell — {desc}.
// A package-level global of this type shape must COMPILE and read back its
// value. See ../README.md.

"""


def _emit(reads):
    out = []
    for r in reads:
        out.append(f"\ttesting.Println({r})")
    return "\n".join(out)


def render(rel, helpers, gdecl, reads):
    out = HEADER.format(desc=rel)
    if helpers:
        out += helpers + "\n\n"
    out += gdecl + "\n\n"
    out += "func main() {\n" + _emit(reads) + "\n}\n"
    return out


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n = 0
    for rel, helpers, gdecl, reads, expected in CELLS:
        n += 1
        bn = render(rel, helpers, gdecl, reads)
        exp = "".join(str(x) + "\n" for x in expected)
        full = os.path.join(DIR, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", exp)):
            path = full + ext
            old = None
            if os.path.exists(path):
                with open(path) as f:
                    old = f.read()
            if old != content:
                changed.append(os.path.relpath(path, os.path.dirname(DIR)))
                if not check:
                    with open(path, "w") as f:
                        f.write(content)
    if check:
        if changed:
            print("globals matrix out of date (run conformance/gen-globals-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("globals matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
