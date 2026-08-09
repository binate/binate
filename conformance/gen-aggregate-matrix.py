#!/usr/bin/env python3
"""Generate conformance/matrix/aggregate cells — value-movement correctness for
plain (non-managed) values: does every element/field survive a given movement
form?  (The sibling matrices cover adjacent
classes — `abi` covers call-boundary PASSING, `refcount` the managed-value
lifecycle, `const` const materialization — but none covered plain aggregate/
global var ASSIGNMENT, copy, deref, and initializer value correctness.)

Assertion: after the movement, every lane (array element / struct field /
scalar) reads back its expected value.  Self-checking and target-stable:
each lane prints `cast(int, <access> == <literal>)` → 1, so `.expected` is all
1s and a dropped/garbled value prints 0 (or the cell fails to compile).

This net catches the 2026-06-06 defects directly:
  - whole-array/struct `=` assignment silently dropped (the `assign`/`copy`/
    `deref`/`field` forms over array/struct kinds), and the global-array
    initializer drop it caused (the `global` form);
  - a global float `var` emitting invalid LLVM (`global double 0`) — the
    `global` form over the `scalar-float` kind.

Axes: conformance/matrix/aggregate/<form>/<kind>.bn.  Coordinate-addressed
(path = identity); regeneration is idempotent and never touches `.xfail.<mode>`.
Run: `python3 conformance/gen-aggregate-matrix.py [--check]`.  Python now;
intended to port to Binate (dogfood) later — see ../matrix/README.md.
"""

import os
import sys

AGG_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "aggregate")

# Per-kind description.  `elemtyp` is the Binate scalar spelling; `vals` are the
# three distinct lane values (so a swapped/dropped lane is caught); `shape` is
# array | struct | scalar.  Float values are non-integers so the `== lit` check
# can't pass by an accidental int truncation.
KINDS = {
    "scalar-int":   {"shape": "scalar", "elemtyp": "int",     "vals": [11]},
    "scalar-float": {"shape": "scalar", "elemtyp": "float64", "vals": [1.5]},
    "array-int":    {"shape": "array",  "elemtyp": "int",     "vals": [11, 22, 33]},
    "array-float":  {"shape": "array",  "elemtyp": "float64", "vals": [1.5, 2.5, 3.5]},
    "struct-int":   {"shape": "struct", "elemtyp": "int",     "vals": [11, 22, 33]},
    "struct-float": {"shape": "struct", "elemtyp": "float64", "vals": [1.5, 2.5, 3.5]},
}


def lit(v):
    """A Binate literal for a lane value (floats keep a decimal point)."""
    return str(v) if isinstance(v, int) else repr(float(v))


def zero(v):
    """A distinct 'initial' value, so a dropped movement leaves a wrong lane."""
    return "0" if isinstance(v, int) else "0.0"


def typ(kind):
    """The Binate type spelling for a kind ('int', 'float64', '[3]int', 'S')."""
    k = KINDS[kind]
    if k["shape"] == "scalar":
        return k["elemtyp"]
    if k["shape"] == "array":
        return f"[{len(k['vals'])}]{k['elemtyp']}"
    return "S"  # struct


def ptr_typ(kind):
    """Raw-pointer-to-T spelling (`*int`, `*([3]int)`, `*S`)."""
    t = typ(kind)
    return f"*({t})" if t.startswith("[") else f"*{t}"


def struct_decl(kind):
    """`type S struct { f0 T; f1 T; f2 T }` for struct kinds, else ''."""
    k = KINDS[kind]
    if k["shape"] != "struct":
        return ""
    lines = ["type S struct {"]
    for i in range(len(k["vals"])):
        lines.append(f"\tf{i} {k['elemtyp']}")
    lines.append("}")
    return "\n".join(lines)


def composite(kind, source):
    """A composite literal for `kind`. source='target' uses the lane values;
    source='zero' uses the distinct initial value."""
    k = KINDS[kind]
    pick = (lambda v: lit(v)) if source == "target" else (lambda v: zero(v))
    if k["shape"] == "scalar":
        return pick(k["vals"][0])
    if k["shape"] == "array":
        return f"{typ(kind)}{{{', '.join(pick(v) for v in k['vals'])}}}"
    fields = ", ".join(f"f{i}: {pick(v)}" for i, v in enumerate(k["vals"]))
    return f"S{{{fields}}}"


def lanes(kind, base):
    """List of (access-expr, expected-literal) checks for `base` (a var name)."""
    k = KINDS[kind]
    out = []
    for i, v in enumerate(k["vals"]):
        if k["shape"] == "scalar":
            acc = base
        elif k["shape"] == "array":
            acc = f"{base}[{i}]"
        else:
            acc = f"{base}.f{i}"
        out.append((acc, lit(v)))
    return out


def checks(kind, base):
    """Body lines that print `cast(int, access == lit)` per lane; + the count."""
    ls = lanes(kind, base)
    return [f"testing.Println(cast(int, {acc} == {ex}))" for acc, ex in ls], len(ls)


# --- forms: each returns (helper, body, n_checks) ---

def form_decl_init(kind):
    body = [f"var a {typ(kind)} = {composite(kind, 'target')}"]
    c, n = checks(kind, "a")
    return struct_decl(kind), body + c, n


def form_assign(kind):
    body = [f"var a {typ(kind)} = {composite(kind, 'zero')}",
            f"a = {composite(kind, 'target')}"]
    c, n = checks(kind, "a")
    return struct_decl(kind), body + c, n


def form_copy(kind):
    body = [f"var a {typ(kind)} = {composite(kind, 'zero')}",
            f"var b {typ(kind)} = {composite(kind, 'target')}",
            "a = b"]
    c, n = checks(kind, "a")
    return struct_decl(kind), body + c, n


def form_deref(kind):
    body = [f"var a {typ(kind)} = {composite(kind, 'zero')}",
            f"var p {ptr_typ(kind)} = &a",
            f"*p = {composite(kind, 'target')}"]
    c, n = checks(kind, "a")
    return struct_decl(kind), body + c, n


def form_global(kind):
    # The aggregate/scalar lives at package scope; __init applies its
    # initializer.  Catches the global-array drop and the global-float-zero.
    helper = struct_decl(kind)
    glob = f"var g {typ(kind)} = {composite(kind, 'target')}"
    helper = (helper + "\n\n" + glob) if helper else glob
    c, n = checks(kind, "g")
    return helper, c, n


def form_param(kind):
    helper = struct_decl(kind)
    fn = [f"func take(x {typ(kind)}) {{"]
    c, n = checks(kind, "x")
    fn += ["\t" + ln for ln in c]
    fn += ["}"]
    helper = (helper + "\n\n" + "\n".join(fn)) if helper else "\n".join(fn)
    body = [f"var a {typ(kind)} = {composite(kind, 'target')}", "take(a)"]
    return helper, body, n


def form_return(kind):
    helper = struct_decl(kind)
    fn = [f"func mk() {typ(kind)} {{",
          f"\tvar a {typ(kind)} = {composite(kind, 'target')}",
          "\treturn a", "}"]
    helper = (helper + "\n\n" + "\n".join(fn)) if helper else "\n".join(fn)
    body = [f"var a {typ(kind)} = mk()"]
    c, n = checks(kind, "a")
    return helper, body + c, n


def form_field(kind):
    # Aggregate-only: store the aggregate into a struct field, read back.
    helper = struct_decl(kind)
    wrap = f"type W struct {{\n\tagg {typ(kind)}\n}}"
    helper = (helper + "\n\n" + wrap) if helper else wrap
    body = ["var w W", f"w.agg = {composite(kind, 'target')}"]
    c, n = checks(kind, "w.agg")
    return helper, body + c, n


# form name -> (builder, applies-to-shapes)
FORMS = {
    "decl-init": (form_decl_init, ("scalar", "array", "struct")),
    "assign":    (form_assign,    ("scalar", "array", "struct")),
    "copy":      (form_copy,      ("scalar", "array", "struct")),
    "deref":     (form_deref,     ("scalar", "array", "struct")),
    "global":    (form_global,    ("scalar", "array", "struct")),
    "param":     (form_param,     ("scalar", "array", "struct")),
    "return":    (form_return,    ("scalar", "array", "struct")),
    "field":     (form_field,     ("array", "struct")),  # scalar field == plain struct
}

HEADER = """package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-aggregate-matrix.py — do not edit by hand.
// Aggregate value-movement cell — form={form}, kind={kind}.
// Every lane must read back its value after the movement; a dropped or
// garbled aggregate/global prints 0 here. See ../../README.md.

"""


def all_cells():
    for form, (builder, shapes) in FORMS.items():
        for kind, k in KINDS.items():
            if k["shape"] not in shapes:
                continue
            helper, body, n = builder(kind)
            yield (os.path.join(form, kind), form, kind, helper, body, n)


def render(form, kind, helper, body):
    out = HEADER.format(form=form, kind=kind)
    if helper:
        out += helper + "\n\n"
    out += "func main() {\n"
    for ln in body:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    for rel, form, kind, helper, body, n in all_cells():
        bn = render(form, kind, helper, body)
        exp = "1\n" * n
        full = os.path.join(AGG_DIR, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", exp)):
            path = full + ext
            old = None
            if os.path.exists(path):
                with open(path) as f:
                    old = f.read()
            if old != content:
                changed.append(os.path.relpath(path, os.path.dirname(AGG_DIR)))
                if not check:
                    with open(path, "w") as f:
                        f.write(content)
    if check:
        if changed:
            print("aggregate matrix out of date (run conformance/gen-aggregate-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("aggregate matrix up to date")
        return 0
    print(f"aggregate matrix: wrote/updated {len(changed)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
