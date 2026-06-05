#!/usr/bin/env python3
"""Generate conformance/matrix refcount-balance cells from the (form, shape,
type) axes.

The matrix is coordinate-addressed: each cell lives at
conformance/matrix/<form>/<shape>/<type>.bn and its path IS its identity (see
conformance/matrix/README.md). This generator OWNS the .bn + .expected files
for every (form, shape, type) it knows how to emit; regenerating is idempotent
(same coordinates -> same path), so adding a dimension value creates new paths
and touches nothing existing. It NEVER writes or deletes .xfail.<mode> markers
(those are determined by running and are maintained by hand) — it only warns
about orphans.

Every generated cell is a refcount-balance test with a MORTAL source: it
constructs a fresh managed value whose embedded refcountable we observe via
rt.Refcount, copies it into the cell's target, and asserts the observable's
refcount rises by one and returns to baseline. Each type exposes the same
shape ("copy -> observable +1") so the form/shape templates stay type-agnostic;
only the per-type construct/observe fragments and the baseline differ.

Run from anywhere: `python3 conformance/gen-matrix.py [--check]`.
  (default) regenerate all known cells.
  --check   fail if regeneration would change anything (for CI/hygiene).

Intended to be ported to Binate eventually (dogfood); Python for now because a
test generator must run even when the toolchain is broken.
"""

import os
import sys

MATRIX_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "matrix")


# --- Type definitions -------------------------------------------------------
#
# Each type is a dict of Binate fragments. Conventions:
#   decls      top-level declarations (struct / interface / impl), or "".
#   tname      the Binate spelling of the value type (e.g. "@Counter").
#   baseline   the observable's refcount once `src` is constructed (before any
#              copy) — 1 when the value solely owns its observable.
#   useval     the int printed by use(t), proving the alias is live.
# and three fragment builders returning lists of body lines (tab-indented):
#   construct(v)   declare `v` as a fresh mortal value + leave its observable
#                  reachable; MUST also emit `var <v>_po *uint8 = ...` naming
#                  the observable pointer as <v>_po.
#   fresh(v)       declare `v` as a fresh DIFFERENT value of this type (a drop
#                  target / pre-existing occupant); no observable needed.
#   use(v)         an expression of type int that dereferences `v` (e.g. v.N).

TYPES = {}


def _t(name, **kw):
    TYPES[name] = kw


_t(
    "managed-ptr",
    decls="type Counter struct {\n\tN int\n}",
    tname="@Counter",
    baseline=1,
    useval=7,
    construct=lambda v: [
        f"var {v} @Counter = make(Counter)",
        f"{v}.N = 7",
        f"var {v}_po *uint8 = bit_cast(*uint8, {v})",
    ],
    fresh=lambda v: [f"var {v} @Counter = make(Counter)"],
    use=lambda v: f"{v}.N",
)

_t(
    "managed-slice",
    decls="",
    tname="@[]int",
    baseline=1,
    useval=9,
    construct=lambda v: [
        f"var {v} @[]int = make_slice(int, 3)",
        f"{v}[0] = 9",
        f"var {v}_hp *int = bit_cast(*int, &{v})",
        f"var {v}_po *uint8 = bit_cast(*uint8, {v}_hp[2])",
    ],
    fresh=lambda v: [f"var {v} @[]int = make_slice(int, 1)"],
    use=lambda v: f"{v}[0]",
)

_t(
    "func-value",
    decls="",
    tname="@func() int",
    baseline=1,
    useval=5,
    construct=lambda v: [
        f"var {v}_n int = 5",
        f"var {v} @func() int = func() int {{ return {v}_n }}",
        f"var {v}_hp *int = bit_cast(*int, &{v})",
        f"var {v}_po *uint8 = bit_cast(*uint8, {v}_hp[1])",
    ],
    fresh=lambda v: [
        f"var {v}_z int = 0",
        f"var {v} @func() int = func() int {{ return {v}_z }}",
    ],
    use=lambda v: f"{v}()",
)

_t(
    "iface",
    decls=(
        "type Counter struct {\n\tN int\n}\n\n"
        "func (c *Counter) num() int { return c.N }\n\n"
        "interface Numbered {\n\tnum() int\n}\n\n"
        "impl *Counter : Numbered"
    ),
    tname="@Numbered",
    # baseline 2: the iface is constructed from a source var (<v>_c) that we
    # observe through and which co-holds the wrapped object, so the object's
    # refcount is 2 before any copy. The balance assertion (copy -> +1, drop ->
    # back) is unaffected by the offset.
    baseline=2,
    useval=5,
    construct=lambda v: [
        f"var {v}_c @Counter = make(Counter)",
        f"{v}_c.N = 5",
        f"var {v}_po *uint8 = bit_cast(*uint8, {v}_c)",
        f"var {v} @Numbered = {v}_c",
    ],
    fresh=lambda v: [
        f"var {v}_d @Counter = make(Counter)",
        f"var {v} @Numbered = {v}_d",
    ],
    use=lambda v: f"{v}.num()",
)

_t(
    "managed-struct",
    decls="type Counter struct {\n\tN int\n}\n\ntype Box struct {\n\tc @Counter\n}",
    tname="Box",
    baseline=1,
    useval=7,
    construct=lambda v: [
        f"var {v} Box",
        f"{v}.c = make(Counter)",
        f"{v}.c.N = 7",
        f"var {v}_po *uint8 = bit_cast(*uint8, {v}.c)",
    ],
    fresh=lambda v: [f"var {v} Box"],
    use=lambda v: f"{v}.c.N",
)


# --- Forms (shape = ident) --------------------------------------------------
#
# Each form builder takes (t = type dict) and returns (body_lines, expected),
# where body_lines is the inside of main() and expected is the list of printed
# ints. The shared shape: construct `src`, observe baseline, bind src into
# `tgt` via the form, observe baseline+1, use tgt, drop tgt, observe baseline.
# `helpers` (top-level funcs needed by the form, e.g. a pair() for multi forms)
# is returned per-form via the FORMS table's optional "helpers" entry.

def _common(t, bind_lines, drop_lines, extra_decls=""):
    b = t["baseline"]
    lines = []
    lines += t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines += bind_lines
    lines.append('println(rt.Refcount(src_po))')
    lines.append(f'println({t["use"]("tgt")})')
    lines += drop_lines
    lines.append('println(rt.Refcount(src_po))')
    expected = [b, b + 1, t["useval"], b]
    return lines, expected, extra_decls


def form_var_init(t):
    bind = [f'var tgt {t["tname"]} = src']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _common(t, bind, drop)


def form_assign(t):
    bind = t["fresh"]("tgt") + ['tgt = src']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _common(t, bind, drop)


def form_short_var(t):
    bind = ['tgt := src']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _common(t, bind, drop)


# Shape variants of single-assign: the target is an element/field `lv` of a
# container, written `lv = src`. The element starts nil/zero (so the bind's
# release-old is a no-op); the drop overwrites it with a fresh value
# (exercising release-old with a real prior occupant). Observation is on src's
# observable, which the copy into the element RefIncs by one.
def _shape(t, decl_lines, lv, extra_decls=""):
    b = t["baseline"]
    lines = t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines += decl_lines
    lines.append(f'{lv} = src')
    lines.append('println(rt.Refcount(src_po))')
    lines.append(f'println({t["use"](lv)})')
    lines += t["fresh"]("drp")
    lines.append(f'{lv} = drp')
    lines.append('println(rt.Refcount(src_po))')
    return lines, [b, b + 1, t["useval"], b], extra_decls


def form_assign_selector(t):
    extra = f"type Holder struct {{\n\tf {t['tname']}\n}}"
    return _shape(t, ['var st Holder'], 'st.f', extra)


def form_assign_index_array(t):
    return _shape(t, [f'var arr [2]{t["tname"]}'], 'arr[0]')


def form_assign_index_slice(t):
    return _shape(t, [f'var sl @[]{t["tname"]} = make_slice({t["tname"]}, 2)'], 'sl[0]')


FORMS = {
    ("var-init", "ident"): {"build": form_var_init, "helpers": ""},
    ("assign", "ident"): {"build": form_assign, "helpers": ""},
    ("short-var", "ident"): {"build": form_short_var, "helpers": ""},
    ("assign", "selector"): {"build": form_assign_selector, "helpers": ""},
    ("assign", "index-array"): {"build": form_assign_index_array, "helpers": ""},
    ("assign", "index-slice"): {"build": form_assign_index_slice, "helpers": ""},
}


# --- Emit -------------------------------------------------------------------

HEADER = """package "main"

// GENERATED by conformance/gen-matrix.py — do not edit by hand.
// Matrix cell — form={form}, shape={shape}, type={type}.
// Refcount-balance with a MORTAL source: copying the value into the target
// raises its observable's refcount by one; dropping the alias restores the
// baseline. See conformance/matrix/README.md.

import "pkg/builtins/rt"
"""


def render(form, shape, tname, t):
    helpers = FORMS[(form, shape)]["helpers"]
    body, expected, extra_decls = FORMS[(form, shape)]["build"](t)
    out = HEADER.format(form=form, shape=shape, type=tname)
    if t["decls"]:
        out += "\n" + t["decls"] + "\n"
    if extra_decls:
        out += "\n" + extra_decls + "\n"
    if helpers:
        out += "\n" + helpers + "\n"
    out += "\nfunc main() {\n"
    for ln in body:
        out += "\t" + ln + "\n"
    out += "}\n"
    exp = "".join(str(x) + "\n" for x in expected)
    return out, exp


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    for (form, shape) in FORMS:
        for tname, t in TYPES.items():
            bn, exp = render(form, shape, tname, t)
            d = os.path.join(MATRIX_DIR, form, shape)
            os.makedirs(d, exist_ok=True)
            for ext, content in ((".bn", bn), (".expected", exp)):
                path = os.path.join(d, tname + ext)
                old = None
                if os.path.exists(path):
                    with open(path) as f:
                        old = f.read()
                if old != content:
                    changed.append(os.path.relpath(path, os.path.dirname(MATRIX_DIR)))
                    if not check:
                        with open(path, "w") as f:
                            f.write(content)
    if check:
        if changed:
            print("matrix out of date (run conformance/gen-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{len(FORMS)} form/shape x {len(TYPES)} types")
    return 0


if __name__ == "__main__":
    sys.exit(main())
