#!/usr/bin/env python3
"""Generate conformance/matrix/dispatch-refcount cells — refcount balance of a
MANAGED multi-return component produced through an INDIRECT call (the
indirect-producer axis the refcount matrix never crossed).

The result-side dispatch value/packing was fixed (the MethodResultsFlat SEAM,
`6c39d460`); this matrix asks the *refcount* question its value-only sibling
(`matrix/abi`) can't see: when an interface-method dispatch returns a managed
component, does the component arrive with exactly one added ref (Axiom-3) and get
released when the destructured alias drops — no leak, no use-after-free — on every
backend? (A compile-only or VM-only check would miss a native refcount divergence,
exactly as the abi result-side sweep found for value/packing.)

Each cell holds a managed value alive through a surviving alias (so its refcount
observable stays valid), captures the refcount BEFORE the dispatch, destructures
the managed component out of the dispatch's multi-return, and asserts the
BALANCE INVARIANT directly — `after == before + 1` and `final == before` — so the
cell is robust to the absolute baseline and passes iff the discipline is correct.
Output per cell: `1` (dispatch added one ref), the component's value, `1`
(balanced after drop).

Axes: `<producer>/<component>` (currently producer = iface-dispatch; component =
managed-ptr / func-value / iface). Coordinate-addressed.
Run: python3 conformance/gen-dispatch-refcount-matrix.py [--check].
"""

import os
import sys

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "matrix", "dispatch-refcount")

# (relpath, helpers, body[list of statements]). Every cell asserts [1, 42, 1].
CELLS = [
    ("iface-dispatch/managed-ptr",
     "type Counter struct {\n\tn int\n}\n\n"
     "interface Maker {\n\tmk() (int, @Counter)\n}\n\n"
     "type Impl struct {\n\tc @Counter\n}\n\n"
     "func (im *Impl) mk() (int, @Counter) {\n\treturn 0, im.c\n}\n\n"
     "impl *Impl : Maker",
     ["var src @Counter = make(Counter)", "src.n = 42",
      "var po *uint8 = bit_cast(*uint8, src)",
      "var im @Impl = make(Impl)", "im.c = src", "var m @Maker = im",
      "var before int = rt.Refcount(po)",
      "var x int", "var g @Counter", "x, g = m.mk()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g.n)",
      "var drp @Counter = make(Counter)", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),

    ("iface-dispatch/func-value",
     "interface Maker {\n\tmk() (int, @func() int)\n}\n\n"
     "type Impl struct {\n\tf @func() int\n}\n\n"
     "func (im *Impl) mk() (int, @func() int) {\n\treturn 0, im.f\n}\n\n"
     "impl *Impl : Maker",
     ["var n int = 42", "var src @func() int = func() int { return n }",
      "var hp *int = bit_cast(*int, &src)",
      "var po *uint8 = bit_cast(*uint8, hp[1])",
      "var im @Impl = make(Impl)", "im.f = src", "var m @Maker = im",
      "var before int = rt.Refcount(po)",
      "var x int", "var g @func() int", "x, g = m.mk()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g())",
      # drop g via a var-init (the FV hint applies there) — a bare
      # `g = func(){…}` assignment hits the separate func-literal-flavour bug.
      "var drp @func() int = func() int { return 0 }", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),

    ("iface-dispatch/iface",
     "type Counter struct {\n\tn int\n}\n\n"
     "func (c *Counter) num() int {\n\treturn c.n\n}\n\n"
     "interface Numbered {\n\tnum() int\n}\n\n"
     "impl *Counter : Numbered\n\n"
     "interface Maker {\n\tmk() (int, @Numbered)\n}\n\n"
     "type Impl struct {\n\tiv @Numbered\n}\n\n"
     "func (im *Impl) mk() (int, @Numbered) {\n\treturn 0, im.iv\n}\n\n"
     "impl *Impl : Maker",
     ["var c @Counter = make(Counter)", "c.n = 42",
      "var po *uint8 = bit_cast(*uint8, c)",
      "var src @Numbered = c",
      "var im @Impl = make(Impl)", "im.iv = src", "var m @Maker = im",
      "var before int = rt.Refcount(po)",
      "var x int", "var g @Numbered", "x, g = m.mk()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g.num())",
      "var c2 @Counter = make(Counter)", "var drp @Numbered = c2", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),

    ("iface-dispatch/managed-slice",
     "interface Maker {\n\tmk() (int, @[]int)\n}\n\n"
     "type Impl struct {\n\ts @[]int\n}\n\n"
     "func (im *Impl) mk() (int, @[]int) {\n\treturn 0, im.s\n}\n\n"
     "impl *Impl : Maker",
     ["var src @[]int = make_slice(int, 3)", "src[0] = 42",
      "var hp *int = bit_cast(*int, &src)",
      "var po *uint8 = bit_cast(*uint8, hp[2])",
      "var im @Impl = make(Impl)", "im.s = src", "var m @Maker = im",
      "var before int = rt.Refcount(po)",
      "var x int", "var g @[]int", "x, g = m.mk()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g[0])",
      "var drp @[]int = make_slice(int, 1)", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),

    # --- funcval producer (a NON-capturing func reading a global — a capturing
    #     closure returning a multi-return is the separate LLVM bug filed in
    #     claude-todo CRITICAL). ---
    ("funcval/managed-ptr",
     "type Counter struct {\n\tn int\n}\n\n"
     "var gc @Counter = make(Counter)\n\n"
     "func produce() (int, @Counter) {\n\treturn 0, gc\n}",
     ["gc.n = 42",
      "var po *uint8 = bit_cast(*uint8, gc)",
      "var before int = rt.Refcount(po)",
      "var f @func() (int, @Counter) = produce",
      "var x int", "var g @Counter", "x, g = f()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g.n)",
      "var drp @Counter = make(Counter)", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),

    ("funcval/managed-slice",
     "var gs @[]int = make_slice(int, 3)\n\n"
     "func produce() (int, @[]int) {\n\treturn 0, gs\n}",
     ["gs[0] = 42",
      "var hp *int = bit_cast(*int, &gs)",
      "var po *uint8 = bit_cast(*uint8, hp[2])",
      "var before int = rt.Refcount(po)",
      "var f @func() (int, @[]int) = produce",
      "var x int", "var g @[]int", "x, g = f()",
      "testing.Println(cast(int, rt.Refcount(po) == before + 1))",
      "testing.Println(g[0])",
      "var drp @[]int = make_slice(int, 1)", "g = drp",
      "testing.Println(cast(int, rt.Refcount(po) == before))"]),
]
EXPECTED = [1, 42, 1]

HEADER = """package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-dispatch-refcount-matrix.py — do not edit by hand.
// dispatch-refcount matrix cell — {desc}.
// A managed component destructured from an interface-dispatch multi-return must
// arrive with exactly one added ref and be released when the alias drops — no
// leak, no UAF — on every backend. Output: 1 (added one ref), value, 1 (balanced).
// See ../README.md.

import "pkg/builtins/rt"

"""


def render(rel, helpers, body):
    out = HEADER.format(desc=rel)
    if helpers:
        out += helpers + "\n\n"
    out += "func main() {\n"
    for ln in body:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n = 0
    exp = "".join(str(x) + "\n" for x in EXPECTED)
    for rel, helpers, body in CELLS:
        n += 1
        bn = render(rel, helpers, body)
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
            print("dispatch-refcount matrix out of date (run conformance/gen-dispatch-refcount-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("dispatch-refcount matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
