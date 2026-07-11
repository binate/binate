#!/usr/bin/env python3
"""Generate conformance/matrix/generic-managed cells — link+run and refcount
balance for a generic CONTAINER holding a MANAGED element, across the two axes
that hid the recent bug cluster:

  * SITE — in-package vs cross-package.  In-package coincidentally aligns the
    mangled call/def prefixes; cross-package diverges (8d9e7577's dtor-mangling
    mismatch, c14dd95e/aba92526's named-wrapper helper emission).
  * ELEMENT KIND — managed-ptr @Counter, managed-slice @[]int, named-distinct
    wrapper `type Buf @[]@Box`, named array `type NArr [3]@Box`, …

Two invariants, two cell shapes:
  * BALANCE cells (element has a single clean refcount observable): hold a mortal
    managed value in a Holder[T] and assert the RELATIVE invariant
    rt.Refcount(po) == before+1 (held) and == before (after the Holder drops) —
    no leak, no UAF, on every backend.  Output column [1, <value>, 1].
  * LINK+RUN cells (named wrapper / array element): construct an EMPTY / never-
    populated Holder and let it drop at scope end — the element dtor/copy helper
    must be EMITTED (the empty case is exactly what hid c14dd95e/aba92526).
    Output the element count (0).

Cross-package cells put the body-included generic Holder in a per-cell
pkg/gh.bni (mirroring conformance/995's gholder.bni — self-contained, so
conformance-imports stays green; NEVER import pkg/stdx/containers/*).  In-package
cells define Holder in the single .bn.  Coordinate-addressed:
matrix/generic-managed/<site>/<kind>/<op>{.bn | /main.bn}.

Run: python3 conformance/gen-generic-managed-matrix.py [--check].
See explorations/plan-matrix-tests-generics-rtti.md.
"""

import os
import sys

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "matrix", "generic-managed")

# The generic container, body-included so a cross-package consumer monomorphizes
# it (and usable verbatim in-package).  `Count` lets a link+run cell prove the
# instantiation ran without needing a managed observable.
HOLDER_DECLS = """type Holder[T any] struct {
	items @[]T
	n     int
}

func New[T any]() @Holder[T] {
	var h @Holder[T] = make(Holder[T])
	h.items = make_slice(T, 4)
	h.n = 0
	return h
}

func Put[T any](h @Holder[T], x T) {
	h.items[h.n] = x
	h.n = h.n + 1
}

func At[T any](h @Holder[T], i int) T {
	return h.items[i]
}

func Count[T any](h @Holder[T]) int {
	return h.n
}"""

GH_SENTINEL = 'package "pkg/gh"\n\n// Concrete helper so the fixture package compiles on its own; Holder[T]\'s\n// bodies live in gh.bni for the cross-package consumer to monomorphize.\nfunc Sentinel() int {\n\treturn 1\n}\n'


# --- element kinds ----------------------------------------------------------
# Each: decls (element type declarations), t (the element type spelling),
# construct (statements setting a mortal `src` + its observable `po`), use
# (expression of type int reading element 0 of the held Holder `h`, given the
# call `pfx`).
def managed_ptr(pfx):
    return dict(
        decls="type Counter struct {\n\tn int\n}",
        t="@Counter",
        construct=["var src @Counter = make(Counter)", "src.n = 42",
                   "var po *uint8 = bit_cast(*uint8, src)"],
        use=f"{pfx}At[@Counter](h, 0).n")


def managed_slice(pfx):
    return dict(
        decls="",
        t="@[]int",
        construct=["var src @[]int = make_slice(int, 3)", "src[0] = 42",
                   "var hp *int = bit_cast(*int, &src)",
                   "var po *uint8 = bit_cast(*uint8, hp[2])"],
        use=f"{pfx}At[@[]int](h, 0)[0]")


def managed_struct(pfx):
    # element is a struct-with-a-managed-field (by value); the container copies the
    # struct in (RefInc the field) and RefDec's it on destroy.  Observe the field.
    return dict(
        decls="type Counter struct {\n\tn int\n}\n\ntype Box struct {\n\tc @Counter\n}",
        t="Box",
        construct=["var src Box", "src.c = make(Counter)", "src.c.n = 42",
                   "var po *uint8 = bit_cast(*uint8, src.c)"],
        use=f"{pfx}At[Box](h, 0).c.n")


def func_value(pfx):
    return dict(
        decls="",
        t="@func() int",
        construct=["var nn int = 42", "var src @func() int = func() int { return nn }",
                   "var hp *int = bit_cast(*int, &src)",
                   "var po *uint8 = bit_cast(*uint8, hp[1])"],
        use=f"{pfx}At[@func() int](h, 0)()")


BALANCE_KINDS = {"managed-ptr": managed_ptr, "managed-slice": managed_slice,
                 "managed-struct": managed_struct, "func-value": func_value}

# NOTE: a managed-interface element (`@Numbered`) balance cell is deferred — its
# natural value-use (`At[@Numbered](h,0).num()`) hits a SEPARATE bug: an interface
# method call on a generic-function-call RESULT emits an undefined method symbol
# (`bn_..._num` referenced-but-not-defined), the sibling of conformance/168's
# method-VALUE case (2d48f348/fedbd0c5 fixed the method-value path but not the
# interface-method-CALL path). Tracked separately (claude-todo + a dedicated
# conformance repro); the iface element holds/releases correctly through the
# container (a var-bound read links + balances), so this is a call-on-result bug,
# not an iface-in-container bug.


def named_wrapper(pfx):
    # element is a named-distinct managed-slice wrapper (the c14dd95e shape).
    return dict(decls="type Box struct {\n\tv int\n}\n\ntype Buf @[]@Box", t="Buf")


def named_array(pfx):
    # element is a named array of managed pointers (the aba92526 arm-ii shape).
    return dict(decls="type Box struct {\n\tv int\n}\n\ntype NArr [3]@Box", t="NArr")


LINKRUN_KINDS = {"named-wrapper": named_wrapper, "named-array": named_array}


# --- bodies -----------------------------------------------------------------
def balance_body(e, pfx):
    return e["construct"] + [
        f'var h @{pfx}Holder[{e["t"]}] = {pfx}New[{e["t"]}]()',
        "var before int = rt.Refcount(po)",
        f'{pfx}Put[{e["t"]}](h, src)',
        "println(cast(int, rt.Refcount(po) == before + 1))",
        f'println({e["use"]})',
        f'var drp @{pfx}Holder[{e["t"]}] = {pfx}New[{e["t"]}]()',
        "h = drp",
        "println(cast(int, rt.Refcount(po) == before))",
    ]


def linkrun_body(e, pfx):
    # EMPTY / never-populated: the Holder drops at scope end and its dtor walks
    # the (empty) backing — the element dtor helper must exist.  Count == 0.
    return [
        f'var h @{pfx}Holder[{e["t"]}] = {pfx}New[{e["t"]}]()',
        f'println({pfx}Count[{e["t"]}](h))',
    ]


BALANCE_EXPECTED = [1, 42, 1]
LINKRUN_EXPECTED = [0]

HEADER = '''package "main"

// GENERATED by conformance/gen-generic-managed-matrix.py — do not edit by hand.
// generic-managed matrix cell — {desc}.
// {inv}
// See ../../README.md and plan-matrix-tests-generics-rtti.md.

import "pkg/builtins/rt"
'''

BAL_INV = "A managed element held in a generic container gains exactly one ref and is released when the container drops (== before+1, then == before) — no leak, no UAF."
LR_INV = "A cross/in-package generic container over a named-wrapper/array element must EMIT the element dtor helper even when EMPTY (the c14dd95e/aba92526 trigger); links + runs, Count == 0."


def bni(t_decls):
    return (f'package "pkg/gh"\n\n{HOLDER_DECLS}\n')


MV_INV = "A method VALUE taken off a generic instantiation (or a generic-call result) links + runs: the captured-receiver closure struct is named by the MANGLED instantiation name on every name-mangling backend (2d48f348/fedbd0c5)."
DISTINCT_INV = "Two generic instantiations differing ONLY within a structured type arg (array LENGTH, func SIGNATURE) are DISTINCT types; assigning one to the other is a compile error (42b3bc83)."

CELLS = []
for site in ("inpkg", "xpkg"):
    pfx = "" if site == "inpkg" else "gh."
    for kind, mk in BALANCE_KINDS.items():
        e = mk(pfx)
        CELLS.append(dict(site=site, rel=f"{site}/{kind}/balance", inv=BAL_INV, holder=True,
                          decls=e["decls"], body=balance_body(e, pfx), exp=BALANCE_EXPECTED))
    for kind, mk in LINKRUN_KINDS.items():
        e = mk(pfx)
        CELLS.append(dict(site=site, rel=f"{site}/{kind}/empty", inv=LR_INV, holder=True,
                          decls=e["decls"], body=linkrun_body(e, pfx), exp=LINKRUN_EXPECTED))

# method-value cells (holder=False: their own Box[T] with methods, not the Holder
# container).  Link+run — the whole point is exercising name-mangling backends.
CELLS.append(dict(site="inpkg", rel="method-value/scalar", inv=MV_INV, holder=False, exp=[42],
                  decls="type Box[T any] struct {\n\tval T\n}\n\nfunc (b *Box[T]) Get() T {\n\treturn b.val\n}",
                  body=["var bx Box[int]", "bx.val = 42", "var bp *Box[int] = &bx",
                        "var f *func() int = bp.Get", "println(f())"]))
CELLS.append(dict(site="inpkg", rel="method-value/call-result", inv=MV_INV, holder=False, exp=[42],
                  decls=("type Box[T any] struct {\n\tval T\n}\n\n"
                         "func (b @Box[T]) Get() T {\n\treturn b.val\n}\n\n"
                         "func mkbox[T any](v T) @Box[T] {\n\tvar b @Box[T] = make(Box[T])\n\tb.val = v\n\treturn b\n}"),
                  body=["var f *func() int = mkbox[int](42).Get", "println(f())"]))

# type-distinctness compile-error PAIR cells (neg: assign must fail).
CELLS.append(dict(site="inpkg", rel="distinct/array-len", inv=DISTINCT_INV, holder=False,
                  neg=True, err="cannot assign",
                  decls="type Box[T any] struct {\n\tfn T\n}",
                  body=["var b3 @Box[[3]int] = make(Box[[3]int])",
                        "var b5 @Box[[5]int] = make(Box[[5]int])", "b3 = b5"]))
CELLS.append(dict(site="inpkg", rel="distinct/func-sig", inv=DISTINCT_INV, holder=False,
                  neg=True, err="cannot assign",
                  decls="type Box[T any] struct {\n\tfn T\n}",
                  body=["var bi @Box[@func(int) uint] = make(Box[@func(int) uint])",
                        "var bb @Box[@func(bool) uint] = make(Box[@func(bool) uint])", "bi = bb"]))


def render_main(c):
    imp = '\nimport "pkg/gh"\n' if c["site"] == "xpkg" else ""
    out = HEADER.format(desc=c["rel"], inv=c["inv"]) + imp + "\n"
    # holder cells define the generic Holder in-file (in-package) or import it
    # (cross-package); non-holder cells (method-value, distinct) carry their own
    # generic in `decls`.
    decls = c["decls"]
    if c["site"] == "inpkg" and c.get("holder"):
        decls = (decls + "\n\n" if decls else "") + HOLDER_DECLS
    if decls:
        out += decls + "\n\n"
    out += "func main() {\n"
    for ln in c["body"]:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def _write(path, content, changed, check):
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if old != content:
        changed.append(os.path.relpath(path, os.path.dirname(DIR)))
        if not check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(content)


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    for c in CELLS:
        exp = "".join(str(x) + "\n" for x in c.get("exp", []))
        if c["site"] == "inpkg":
            base = os.path.join(DIR, c["rel"])
            _write(base + ".bn", render_main(c), changed, check)
            if c.get("neg"):
                _write(base + ".error", c["err"] + "\n", changed, check)
            else:
                _write(base + ".expected", exp, changed, check)
        else:  # cross-package cell = a directory with main.bn + pkg/gh fixture
            d = os.path.join(DIR, c["rel"])
            _write(os.path.join(d, "main.bn"), render_main(c), changed, check)
            _write(os.path.join(d, "expected"), exp, changed, check)
            _write(os.path.join(d, "pkg", "gh.bni"), bni(c["decls"]), changed, check)
            _write(os.path.join(d, "pkg", "gh", "gh.bn"), GH_SENTINEL, changed, check)
    if check:
        if changed:
            print("generic-managed matrix out of date (run conformance/gen-generic-managed-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("generic-managed matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{len(CELLS)} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
