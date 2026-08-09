#!/usr/bin/env python3
"""Generate conformance/matrix/abi cells — aggregate & multi-return passing
(Class 4 of the code-red taxonomy).

Assertion: every field's VALUE survives crossing a call boundary. A backend
that mis-packs a tuple / aggregate (the x64 multi-return drop, the aa64
non-8-multiple tail-drop, the pointer-not-bytes bug, byval/sret threshold
disagreements) reads a wrong field value here. The shapes are chosen to
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
    # Print a field/value of type t as an int (sub-word/unsigned/float need a cast).
    return f"testing.Println({expr})" if t == "int" else f"testing.Println(cast(int, {expr}))"


def _lit(tname, v):
    # The Binate literal for a multi-return value.  A float type needs a
    # float literal (`100.0`) so the return is float-typed and packs into an
    # FP register (D/XMM); the printed/expected value stays the int form
    # (each cell prints cast(int, field)).
    return f"{v}.0" if tname == "f64" else str(v)


# --- multi-return: type x arity ---
MR_TYPES = {"int": "int", "u16": "uint16", "f64": "float64"}
MR_ARITIES = [2, 3, 4, 5]


def mr_value(tname, i):
    return (i + 1) * (10 if tname == "int" else 100)


def _bind(typ, names, callexpr, form):
    # The binding statement(s) for a multi-return RHS.  "short" => `:=`;
    # "assign" => pre-declared vars + `=`.  The `=` form goes through
    # genMultiAssign, which — for an iface/func-value RHS (no callee name) —
    # must derive component types from the multi-return tuple struct, else a
    # non-int component is mistyped (invalid IR / skipped managed RefInc).
    if form == "short":
        return [f"{', '.join(names)} := {callexpr}"]
    return [f"var {n} {typ}" for n in names] + [f"{', '.join(names)} = {callexpr}"]


def mr_cell(tname, arity, form="short"):
    typ = MR_TYPES[tname]
    vals = [mr_value(tname, i) for i in range(arity)]
    names = [f"a{i}" for i in range(arity)]
    helper = (f"func mr() ({', '.join([typ] * arity)}) {{\n"
              f"\treturn {', '.join(_lit(tname, v) for v in vals)}\n}}")
    body = _bind(typ, names, "mr()", form)
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
    ret = ", ".join(_lit(tname, v) for v in vals)
    return typ, vals, sig, ret


def iface_multi_return_cell(tname, arity, form="short"):
    # Return an N-tuple FROM an interface-method dispatch — the empty
    # {indirect call} × {multi-value result} cell that hid the
    # multi-return-dispatch defect.
    typ, vals, sig, ret = _mr_method_sig(tname, arity)
    names = [f"a{i}" for i in range(arity)]
    helper = ("type Impl struct {\n\tn int\n}\n\n"
              + f"func (im *Impl) mr() ({sig}) {{\n\treturn {ret}\n}}\n\n"
              + f"interface Multi {{\n\tmr() ({sig})\n}}\n\nimpl *Impl : Multi")
    body = ["var m @Multi = make(Impl)"] + _bind(typ, names, "m.mr()", form)
    body += [_print(typ, n) for n in names]
    return helper, body, vals


def funcval_multi_return_cell(tname, arity, form="short"):
    # Return an N-tuple THROUGH a function-value call.
    typ, vals, sig, ret = _mr_method_sig(tname, arity)
    names = [f"a{i}" for i in range(arity)]
    helper = f"func mr() ({sig}) {{\n\treturn {ret}\n}}"
    body = [f"var f @func() ({sig}) = mr"] + _bind(typ, names, "f()", form)
    body += [_print(typ, n) for n in names]
    return helper, body, vals


# --- managed-component multi-return through dispatch: refcount balance ---
# The value MR_TYPES check only that each component's VALUE crosses the boundary;
# a MANAGED component (@Node) must additionally keep its refcount balanced.  Each
# cell threads N persistent @Node through an N-return call (direct free function
# / interface-method dispatch / func-value call) in a `thread` helper that binds
# the returned components (`:=` or `=`) and drops them at scope end; `main` then
# asserts each Node's rc returned to its baseline (1).  A skipped copy-RefInc —
# the multi-return-dispatch defect (fixed in f8916b88, previously covered only at
# the IR-unit level) — leaves an rc wrong (leak) or double-frees (crash).  The
# `=` (genMultiAssign) form on an iface/func-value RHS is the exact site the
# defect hid.

def managed_mr_cell(arity, form, dispatch):
    vals = [mr_value("int", i) for i in range(arity)]
    params = ", ".join(f"x{i} @Node" for i in range(arity))
    rets = ", ".join("@Node" for _ in range(arity))
    passargs = ", ".join(f"x{i}" for i in range(arity))
    anames = [f"a{i}" for i in range(arity)]

    parts = ["type Node struct {\n\tVal int\n}"]
    if dispatch == "iface":
        parts.append("type Impl struct {\n\tn int\n}")
        parts.append(f"func (im *Impl) mr({params}) ({rets}) {{\n\treturn {passargs}\n}}")
        parts.append(f"interface Multi {{\n\tmr({params}) ({rets})\n}}")
        parts.append("impl *Impl : Multi")
        pre = ["var m @Multi = make(Impl)"]
        callexpr = f"m.mr({passargs})"
    elif dispatch == "funcval":
        parts.append(f"func mr({params}) ({rets}) {{\n\treturn {passargs}\n}}")
        pre = [f"var f @func({rets}) ({rets}) = mr"]
        callexpr = f"f({passargs})"
    else:  # direct
        parts.append(f"func mr({params}) ({rets}) {{\n\treturn {passargs}\n}}")
        pre = []
        callexpr = f"mr({passargs})"

    thread_body = pre + _bind("@Node", anames, callexpr, form)
    thread_body += [f"testing.Println({n}.Val)" for n in anames]
    parts.append(f"func thread({params}) {{\n"
                 + "".join("\t" + ln + "\n" for ln in thread_body) + "}")
    helper = "\n\n".join(parts)

    body = []
    for i in range(arity):
        body.append(f"var n{i} @Node = make(Node)")
        body.append(f"n{i}.Val = {vals[i]}")
    body.append(f"thread({', '.join(f'n{i}' for i in range(arity))})")
    for i in range(arity):
        body.append(f"testing.Println(rt.Refcount(bit_cast(*uint8, n{i})))")

    # expected: each component's value (survival), then each Node's rc == 1
    # (balance restored after the threading call).
    return helper, body, vals + [1] * arity


# --- managed field inside a BY-VALUE struct: refcount balance ---
# The value struct cells (struct_return / struct_param / iface_return / ...)
# assert only that each FIELD VALUE survives the call boundary; their fields are
# all value types.  A MANAGED field carried inside a by-value struct must
# additionally keep its refcount balanced across the sites that COPY the struct
# for a new owner: a fresh managed-field struct literal is neither a named local
# nor a call-result temp, so nothing RefDec's its managed field to balance the
# copy a consumer takes — a leak per occurrence (return / by-value arg / method
# return).  Each cell threads a persistent @Node *inside a struct S* through the
# site, drops S, and main asserts the Node's rc returned to its baseline (1) —
# same mechanism as managed_mr_cell.  A leak leaves rc high (wrong-value FAIL); a
# double-free crashes.  'mono' is the lone-@Node-field (16-byte, register-
# returned) minimal-repro shape; 'mixed' adds a leading value field to exercise
# field offset/padding under the managed copy.

MANAGED_STRUCT_SHAPES = {
    # shape -> (value fields before the managed field [(name, type, value)], node Val)
    "mono":  ([], 42),
    "mixed": ([("a", "int", 7)], 42),
}


def _managed_struct_decl(vfields):
    lines = ["type S struct {"]
    for name, t, _ in vfields:
        lines.append(f"\t{name} {t}")
    lines.append("\tn @Node")
    lines.append("}")
    return "\n".join(lines)


def _managed_struct_prelude(vfields):
    return "type Node struct {\n\tVal int\n}\n\n" + _managed_struct_decl(vfields)


def _managed_struct_lit(vfields):
    inits = [f"{name}: {v}" for name, _, v in vfields] + ["n: x"]
    return "S{" + ", ".join(inits) + "}"


def _managed_struct_body(val):
    return ["var n0 @Node = make(Node)", f"n0.Val = {val}", "thread(n0)",
            "testing.Println(rt.Refcount(bit_cast(*uint8, n0)))"]


def managed_struct_return_cell(shape, form):
    # return a managed-field struct literal FROM a free function, bind to a local
    # (short `:=` / typed `var b S =` / pre-declared `=`), read it, drop it.
    vfields, val = MANAGED_STRUCT_SHAPES[shape]
    parts = [_managed_struct_prelude(vfields),
             "func mkS(x @Node) S {\n\treturn " + _managed_struct_lit(vfields) + "\n}"]
    if form == "short":
        bind = ["b := mkS(x)"]
    elif form == "typed":
        bind = ["var b S = mkS(x)"]
    else:  # assign
        bind = ["var b S", "b = mkS(x)"]
    thread_body = bind + ["testing.Println(b.n.Val)"]
    parts.append("func thread(x @Node) {\n"
                 + "".join("\t" + ln + "\n" for ln in thread_body) + "}")
    return "\n\n".join(parts), _managed_struct_body(val), [val, 1]


def managed_struct_param_cell(shape):
    # pass a FRESH managed-field struct literal BY VALUE into a callee, drop.
    # Exercises the by-value-arg locus (a fresh literal copied for the callee's
    # param but never dtor'd).
    vfields, val = MANAGED_STRUCT_SHAPES[shape]
    parts = [_managed_struct_prelude(vfields),
             "func takeS(s S) {\n\ttesting.Println(s.n.Val)\n}",
             "func thread(x @Node) {\n\ttakeS(" + _managed_struct_lit(vfields) + ")\n}"]
    return "\n\n".join(parts), _managed_struct_body(val), [val, 1]


def managed_struct_method_return_cell(shape):
    # return a managed-field struct literal FROM an interface-method dispatch,
    # bind to a typed local, drop — the {indirect call} axis of the leak.
    vfields, val = MANAGED_STRUCT_SHAPES[shape]
    parts = [_managed_struct_prelude(vfields),
             "type Impl struct {\n\tk int\n}",
             "func (im *Impl) mkS(x @Node) S {\n\treturn " + _managed_struct_lit(vfields) + "\n}",
             "interface Maker {\n\tmkS(x @Node) S\n}",
             "impl *Impl : Maker",
             "func thread(x @Node) {\n\tvar mk @Maker = make(Impl)\n"
             "\tvar b S = mk.mkS(x)\n\ttesting.Println(b.n.Val)\n}"]
    return "\n\n".join(parts), _managed_struct_body(val), [val, 1]


COMMENT = """// GENERATED by conformance/gen-abi-matrix.py — do not edit by hand.
// ABI matrix cell — {desc}.
// Every field's value must survive the call boundary; a mis-packed
// tuple/aggregate reads a wrong value here. See ../../README.md.

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
            # `=` (assignment) binding form — exercises genMultiAssign (the
            # `:=` cells above exercise genShortVar).  For an iface/func-value
            # RHS this is the path that mistyped non-int components before
            # `f8916b88`; the same-IR property means each cell's per-mode
            # pass/xfail matches its `:=` sibling (xfail markers mirrored).
            helper, body, vals = mr_cell(tname, arity, "assign")
            yield (os.path.join("multi-return-assign", tname, str(arity)),
                   f"multi-return (= assign form), type={tname}, arity={arity}",
                   helper, body, vals)
            helper, body, vals = iface_multi_return_cell(tname, arity, "assign")
            yield (os.path.join("iface-multi-return-assign", tname, str(arity)),
                   f"multi-return via interface dispatch (= assign form), type={tname}, arity={arity}",
                   helper, body, vals)
            helper, body, vals = funcval_multi_return_cell(tname, arity, "assign")
            yield (os.path.join("funcval-multi-return-assign", tname, str(arity)),
                   f"multi-return via function-value call (= assign form), type={tname}, arity={arity}",
                   helper, body, vals)
    # Managed-component multi-return through each dispatch kind × arity × bind
    # form — the refcount-balance axis (independent of the value MR_TYPES).
    for arity in MR_ARITIES:
        for form, fsuffix in (("short", ""), ("assign", "-assign")):
            for dispatch, dcat in (
                    ("direct", "managed-multi-return"),
                    ("iface", "managed-iface-multi-return"),
                    ("funcval", "managed-funcval-multi-return")):
                helper, body, vals = managed_mr_cell(arity, form, dispatch)
                fdesc = " (= assign form)" if form == "assign" else ""
                yield (os.path.join(dcat + fsuffix, str(arity)),
                       f"managed multi-return via {dispatch}{fdesc} (refcount balance), arity={arity}",
                       helper, body, vals)
    # Managed field inside a BY-VALUE struct — refcount balance for a MANAGED
    # component carried as a struct FIELD (not a direct multi-return component).
    # Threads a persistent @Node inside a struct through return-to-local
    # (short/typed/assign bind forms), by-value literal arg, and interface-
    # dispatch return, asserting rc balance.  Detects the fresh-managed-field-
    # literal copy-without-dtor leak.
    for shape in MANAGED_STRUCT_SHAPES:
        for form in ("short", "typed", "assign"):
            fsuffix = "" if form == "short" else "-" + form
            helper, body, vals = managed_struct_return_cell(shape, form)
            yield (os.path.join("managed-struct-return" + fsuffix, shape),
                   f"managed field in by-value struct, return-to-local ({form} form) "
                   f"(refcount balance), shape={shape}", helper, body, vals)
        helper, body, vals = managed_struct_param_cell(shape)
        yield (os.path.join("managed-struct-param", shape),
               f"managed field in by-value struct, by-value literal arg "
               f"(refcount balance), shape={shape}", helper, body, vals)
        helper, body, vals = managed_struct_method_return_cell(shape)
        yield (os.path.join("managed-struct-iface-return", shape),
               f"managed field in by-value struct, returned via interface dispatch "
               f"(refcount balance), shape={shape}", helper, body, vals)
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
    out = 'package "main"\n\n'
    # Every cell prints via testing.Println (always imported); managed cells
    # additionally use rt.Refcount (auto-detected from the cell text).
    out += 'import "pkg/builtins/testing"\n'
    text = helper + "\n" + "\n".join(body)
    if "rt." in text:
        out += 'import "pkg/builtins/rt"\n'
    out += "\n"
    out += COMMENT.format(desc=desc)
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
