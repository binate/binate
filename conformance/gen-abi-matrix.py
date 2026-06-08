#!/usr/bin/env python3
"""Generate conformance/matrix/abi cells — aggregate & multi-return passing
(Class 4 of the code-red taxonomy; see explorations/plan-code-red.md §7.1b).

Assertion: every field's VALUE survives crossing a call boundary. A backend
that mis-packs a tuple / aggregate (the x64 multi-return drop, the aa64
non-8-multiple tail-drop, the pointer-not-bytes bug, byval/sret threshold
disagreements — §3.9) reads a wrong field value here. The shapes are chosen to
hit the ABI edges: non-8-multiple sizes, internal padding, sub-word packing,
and arities past the in-register limit.

Categories. The first three cross the boundary through a DIRECT (free-function)
call; the rest re-cross the same result/param through an INDIRECT call — the
call-shape axis — where the byval/sret lowering can diverge:
  - multi-return/<type>/<arity> — a function returns an N-tuple, the caller
    binds all components and asserts each (`a, b, c := f()`).
  - struct-return/<shape>      — a function returns a struct by value; the
    caller reads every field.
  - struct-param/<shape>       — a struct is passed by value; the callee reads
    every field.
  - iface-param/<shape> / funcval-param/<shape> — the same struct passed by
    value through an interface-method dispatch / a function-value call.
  - iface-return/<shape> / funcval-return/<shape> — a struct returned by value
    through a dispatch / a function-value call (the result-side mirror of
    *-param).
  - iface-multi-return/<type>/<arity> / funcval-multi-return/<type>/<arity> —
    an N-tuple returned through a dispatch / a function-value call. The
    {indirect call} × {multi-value result} cell the direct-only result
    categories never exercised — where the multi-return-dispatch defect hid.

Coordinate-addressed (path = identity); regeneration is idempotent and never
touches `.xfail.<mode>`. Run: `python3 conformance/gen-abi-matrix.py [--check]`.
Python now; intended to port to Binate (dogfood) later — see ../matrix/README.md.
"""

import os
import sys

ABI_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "abi")


def _print(t, expr):
    # Print a field/value of type t as an int (sub-word/unsigned need a cast).
    return f"println({expr})" if t == "int" else f"println(cast(int, {expr}))"


# --- multi-return: type x arity ---
MR_TYPES = {"int": "int", "u16": "uint16"}
MR_ARITIES = [2, 3, 4, 5]


def mr_value(tname, i):
    return (i + 1) * (10 if tname == "int" else 100)


def mr_cell(tname, arity):
    typ = MR_TYPES[tname]
    vals = [mr_value(tname, i) for i in range(arity)]
    names = [f"a{i}" for i in range(arity)]
    helper = (f"func mr() ({', '.join([typ] * arity)}) {{\n"
              f"\treturn {', '.join(str(v) for v in vals)}\n}}")
    body = [f"{', '.join(names)} := mr()"]
    body += [_print(typ, n) for n in names]
    return helper, body, vals


# --- struct shapes: (name, [(field-type, value), ...]) chosen to stress the
# size/padding/packing edges. ---
STRUCTS = [
    ("two-int", [("int", 10), ("int", 20)]),                  # 16B, at sret edge
    ("three-int", [("int", 10), ("int", 20), ("int", 30)]),    # 24B -> sret
    ("three-u32", [("uint32", 100), ("uint32", 200), ("uint32", 300)]),  # 12B, non-8-mult
    ("u16-int", [("uint16", 7), ("int", 1000)]),               # internal padding
    ("int-u8", [("int", 1000), ("uint8", 9)]),                 # 9B data, non-8-mult
    ("five-u8", [("uint8", 1), ("uint8", 2), ("uint8", 3),
                 ("uint8", 4), ("uint8", 5)]),                 # 5B, sub-word packing
]


def _struct_decl(fields):
    lines = ["type S struct {"]
    for i, (t, _) in enumerate(fields):
        lines.append(f"\tf{i} {t}")
    lines.append("}")
    return "\n".join(lines)


def struct_return_cell(fields):
    mk = ["func makeS() S {", "\tvar s S"]
    for i, (_, v) in enumerate(fields):
        mk.append(f"\ts.f{i} = {v}")
    mk += ["\treturn s", "}"]
    helper = _struct_decl(fields) + "\n\n" + "\n".join(mk)
    body = ["var s S = makeS()"]
    body += [_print(t, f"s.f{i}") for i, (t, _) in enumerate(fields)]
    return helper, body, [v for _, v in fields]


def struct_param_cell(fields):
    tk = ["func takeS(s S) {"]
    tk += ["\t" + _print(t, f"s.f{i}") for i, (t, _) in enumerate(fields)]
    tk += ["}"]
    helper = _struct_decl(fields) + "\n\n" + "\n".join(tk)
    body = ["var s S"]
    for i, (_, v) in enumerate(fields):
        body.append(f"s.f{i} = {v}")
    body.append("takeS(s)")
    return helper, body, [v for _, v in fields]


def _sink_func(fields):
    tk = ["func sink(s S) {"]
    tk += ["\t" + _print(t, f"s.f{i}") for i, (t, _) in enumerate(fields)]
    tk += ["}"]
    return "\n".join(tk)


def iface_param_cell(fields):
    # Pass the struct by value as an interface-method argument (vtable dispatch).
    helper = (_struct_decl(fields) + "\n\n"
              + "type Impl struct {\n\tn int\n}\n\n"
              + _sink_func(fields).replace("func sink(", "func (im *Impl) sink(")
              + "\n\ninterface Sink {\n\tsink(s S)\n}\n\nimpl *Impl : Sink")
    body = ["var s S"]
    for i, (_, v) in enumerate(fields):
        body.append(f"s.f{i} = {v}")
    body += ["var snk @Sink = make(Impl)", "snk.sink(s)"]
    return helper, body, [v for _, v in fields]


def funcval_param_cell(fields):
    # Pass the struct by value through a function value (lift a named func).
    helper = _struct_decl(fields) + "\n\n" + _sink_func(fields)
    body = ["var s S"]
    for i, (_, v) in enumerate(fields):
        body.append(f"s.f{i} = {v}")
    body += ["var f @func(S) = sink", "f(s)"]
    return helper, body, [v for _, v in fields]


def _source_method(fields):
    # `(im *Impl) makeS() S` — fills every field, returns the struct by value.
    mk = ["func (im *Impl) makeS() S {", "\tvar s S"]
    for i, (_, v) in enumerate(fields):
        mk.append(f"\ts.f{i} = {v}")
    mk += ["\treturn s", "}"]
    return "\n".join(mk)


def _source_func(fields):
    # `makeS() S` — the free-function form of _source_method.
    return _source_method(fields).replace("func (im *Impl) makeS(", "func makeS(")


def iface_return_cell(fields):
    # Return the struct by value FROM an interface-method dispatch (the
    # result-side mirror of iface-param).
    helper = (_struct_decl(fields) + "\n\n"
              + "type Impl struct {\n\tn int\n}\n\n"
              + _source_method(fields)
              + "\n\ninterface Maker {\n\tmakeS() S\n}\n\nimpl *Impl : Maker")
    body = ["var mk @Maker = make(Impl)", "var s S = mk.makeS()"]
    body += [_print(t, f"s.f{i}") for i, (t, _) in enumerate(fields)]
    return helper, body, [v for _, v in fields]


def funcval_return_cell(fields):
    # Return the struct by value THROUGH a function-value call.
    helper = _struct_decl(fields) + "\n\n" + _source_func(fields)
    body = ["var f @func() S = makeS", "var s S = f()"]
    body += [_print(t, f"s.f{i}") for i, (t, _) in enumerate(fields)]
    return helper, body, [v for _, v in fields]


def _mr_method_sig(tname, arity):
    typ = MR_TYPES[tname]
    vals = [mr_value(tname, i) for i in range(arity)]
    sig = ", ".join([typ] * arity)
    ret = ", ".join(str(v) for v in vals)
    return typ, vals, sig, ret


def iface_multi_return_cell(tname, arity):
    # Return an N-tuple FROM an interface-method dispatch — the empty
    # {indirect call} × {multi-value result} cell that hid the
    # multi-return-dispatch defect.
    typ, vals, sig, ret = _mr_method_sig(tname, arity)
    names = [f"a{i}" for i in range(arity)]
    helper = ("type Impl struct {\n\tn int\n}\n\n"
              + f"func (im *Impl) mr() ({sig}) {{\n\treturn {ret}\n}}\n\n"
              + f"interface Multi {{\n\tmr() ({sig})\n}}\n\nimpl *Impl : Multi")
    body = ["var m @Multi = make(Impl)", f"{', '.join(names)} := m.mr()"]
    body += [_print(typ, n) for n in names]
    return helper, body, vals


def funcval_multi_return_cell(tname, arity):
    # Return an N-tuple THROUGH a function-value call.
    typ, vals, sig, ret = _mr_method_sig(tname, arity)
    names = [f"a{i}" for i in range(arity)]
    helper = f"func mr() ({sig}) {{\n\treturn {ret}\n}}"
    body = [f"var f @func() ({sig}) = mr", f"{', '.join(names)} := f()"]
    body += [_print(typ, n) for n in names]
    return helper, body, vals


HEADER = """package "main"

// GENERATED by conformance/gen-abi-matrix.py — do not edit by hand.
// ABI matrix cell — {desc}.
// Every field's value must survive the call boundary; a mis-packed
// tuple/aggregate reads a wrong value here. See ../../README.md and
// plan-code-red.md §3.9.

"""


def all_cells():
    """Yield (relpath-without-ext, desc, helper, body, expected)."""
    for tname in MR_TYPES:
        for arity in MR_ARITIES:
            helper, body, vals = mr_cell(tname, arity)
            yield (os.path.join("multi-return", tname, str(arity)),
                   f"multi-return, type={tname}, arity={arity}", helper, body, vals)
            helper, body, vals = iface_multi_return_cell(tname, arity)
            yield (os.path.join("iface-multi-return", tname, str(arity)),
                   f"multi-return via interface-method dispatch, type={tname}, arity={arity}",
                   helper, body, vals)
            helper, body, vals = funcval_multi_return_cell(tname, arity)
            yield (os.path.join("funcval-multi-return", tname, str(arity)),
                   f"multi-return via function-value call, type={tname}, arity={arity}",
                   helper, body, vals)
    for name, fields in STRUCTS:
        helper, body, vals = struct_return_cell(fields)
        yield (os.path.join("struct-return", name),
               f"struct-return, shape={name}", helper, body, vals)
        helper, body, vals = struct_param_cell(fields)
        yield (os.path.join("struct-param", name),
               f"struct-param (direct call), shape={name}", helper, body, vals)
        helper, body, vals = iface_param_cell(fields)
        yield (os.path.join("iface-param", name),
               f"struct-param via interface-method dispatch, shape={name}", helper, body, vals)
        helper, body, vals = funcval_param_cell(fields)
        yield (os.path.join("funcval-param", name),
               f"struct-param via function-value call, shape={name}", helper, body, vals)
        helper, body, vals = iface_return_cell(fields)
        yield (os.path.join("iface-return", name),
               f"struct-return via interface-method dispatch, shape={name}", helper, body, vals)
        helper, body, vals = funcval_return_cell(fields)
        yield (os.path.join("funcval-return", name),
               f"struct-return via function-value call, shape={name}", helper, body, vals)


def render(desc, helper, body):
    out = HEADER.format(desc=desc)
    out += helper + "\n\nfunc main() {\n"
    for ln in body:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n = 0
    for rel, desc, helper, body, expected in all_cells():
        n += 1
        bn = render(desc, helper, body)
        exp = "".join(str(x) + "\n" for x in expected)
        full = os.path.join(ABI_DIR, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", exp)):
            path = full + ext
            old = None
            if os.path.exists(path):
                with open(path) as f:
                    old = f.read()
            if old != content:
                changed.append(os.path.relpath(path, os.path.dirname(ABI_DIR)))
                if not check:
                    with open(path, "w") as f:
                        f.write(content)
    if check:
        if changed:
            print("abi matrix out of date (run conformance/gen-abi-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("abi matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
