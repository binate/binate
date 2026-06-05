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

MATRIX_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "refcount")


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


# Multi-binding forms destructure a managed component out of a tuple return.
# `pair` returns its argument as the first component (so `src` flows back) plus
# a discarded int. Binding the component must acquire it (RefInc / __copy_)
# exactly as the single forms do.
def _pair_helper(t):
    return f"func pair(v {t['tname']}) ({t['tname']}, int) {{\n\treturn v, 5\n}}"


def form_multi_assign(t):
    bind = t["fresh"]("tgt") + ['tgt, _ = pair(src)']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _common(t, bind, drop, _pair_helper(t))


def form_multi_short_var(t):
    bind = ['tgt, _ := pair(src)']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _common(t, bind, drop, _pair_helper(t))


def form_assign_index_rawptr(t):
    decl = [f'var arr [2]{t["tname"]}', f'var p *{t["tname"]} = &arr[0]']
    return _shape(t, decl, 'p[0]')


# Multi-assign into a non-ident target: destructure the managed component out
# of the tuple straight into an element/field. Same balance shape as _shape;
# the bind is `lv, _ = pair(src)`.
def _multi_shape(t, decl_lines, lv, extra_decls=""):
    helper = _pair_helper(t)
    extra = (extra_decls + "\n\n" + helper) if extra_decls else helper
    b = t["baseline"]
    lines = t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines += decl_lines
    lines.append(f'{lv}, _ = pair(src)')
    lines.append('println(rt.Refcount(src_po))')
    lines.append(f'println({t["use"](lv)})')
    lines += t["fresh"]("drp")
    lines.append(f'{lv} = drp')
    lines.append('println(rt.Refcount(src_po))')
    return lines, [b, b + 1, t["useval"], b], extra


def form_multi_assign_selector(t):
    return _multi_shape(t, ['var st Holder'], 'st.f',
                        f"type Holder struct {{\n\tf {t['tname']}\n}}")


def form_multi_assign_index_array(t):
    return _multi_shape(t, [f'var arr [2]{t["tname"]}'], 'arr[0]')


def form_multi_assign_index_slice(t):
    return _multi_shape(t, [f'var sl @[]{t["tname"]} = make_slice({t["tname"]}, 2)'], 'sl[0]')


def form_multi_assign_index_rawptr(t):
    return _multi_shape(t, [f'var arr [2]{t["tname"]}', f'var p *{t["tname"]} = &arr[0]'], 'p[0]')


# Forms where the value enters via a single observed slot but the writing
# construct differs (a return, or a literal element). Same balance shape as
# _shape; the bind line(s) and any helper/extra-decl vary.
def _slot(t, bind_lines, lv, drop_lines, extra_decls=""):
    b = t["baseline"]
    lines = t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines += bind_lines
    lines.append('println(rt.Refcount(src_po))')
    lines.append(f'println({t["use"](lv)})')
    lines += drop_lines
    lines.append('println(rt.Refcount(src_po))')
    return lines, [b, b + 1, t["useval"], b], extra_decls


def form_return(t):
    # `wrap` not `box` — box is a reserved builtin keyword.
    helper = f"func wrap(v {t['tname']}) {t['tname']} {{\n\treturn v\n}}"
    bind = [f'var tgt {t["tname"]} = wrap(src)']
    drop = t["fresh"]("drp") + ['tgt = drp']
    return _slot(t, bind, "tgt", drop, helper)


def form_composite_lit(t):
    extra = f"type Holder struct {{\n\tf {t['tname']}\n}}"
    bind = ['var h Holder = Holder{f: src}']
    drop = ['var hz Holder', 'h = hz']
    return _slot(t, bind, "h.f", drop, extra)


def form_array_lit(t):
    bind = t["fresh"]("oth") + [f'var arr [2]{t["tname"]} = [2]{t["tname"]}{{src, oth}}']
    drop = t["fresh"]("drp") + ['arr[0] = drp']
    return _slot(t, bind, "arr[0]", drop)


def form_mslice_lit(t):
    bind = t["fresh"]("oth") + [f'var sl @[]{t["tname"]} = @[]{t["tname"]}{{src, oth}}']
    drop = t["fresh"]("drp") + ['sl[0] = drp']
    return _slot(t, bind, "sl[0]", drop)


def form_assign_blank(t):
    # Discard a managed CALL RESULT via `_`. The call-result temp must be
    # released at end of statement; if the producer never registered it as a
    # cleanup temp (the open @func call-result leak), the observable stays
    # elevated instead of returning to baseline.
    helper = f"func wrap(v {t['tname']}) {t['tname']} {{\n\treturn v\n}}"
    b = t["baseline"]
    lines = t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines.append('_ = wrap(src)')
    lines.append('println(rt.Refcount(src_po))')
    return lines, [b, b], helper


def form_param(t):
    # Pass the value as a call argument; the callee holds a ref for the duration
    # (borrow: callee RefIncs at entry; move (@Iface): caller acquires) so the
    # observable reads baseline+1 inside the call and returns to baseline after.
    helper = (f"func take(v {t['tname']}, po *uint8) int {{\n"
              f"\treturn rt.Refcount(po)\n}}")
    b = t["baseline"]
    lines = t["construct"]("src")
    lines.append('println(rt.Refcount(src_po))')
    lines.append('println(take(src, src_po))')
    lines.append('println(rt.Refcount(src_po))')
    return lines, [b, b + 1, b], helper


FORMS = {
    ("var-init", "ident"): {"build": form_var_init, "helpers": ""},
    ("assign", "ident"): {"build": form_assign, "helpers": ""},
    ("short-var", "ident"): {"build": form_short_var, "helpers": ""},
    ("assign", "selector"): {"build": form_assign_selector, "helpers": ""},
    ("assign", "index-array"): {"build": form_assign_index_array, "helpers": ""},
    ("assign", "index-slice"): {"build": form_assign_index_slice, "helpers": ""},
    ("multi-assign", "ident"): {"build": form_multi_assign, "helpers": ""},
    ("multi-short-var", "ident"): {"build": form_multi_short_var, "helpers": ""},
    ("assign", "index-rawptr"): {"build": form_assign_index_rawptr, "helpers": ""},
    ("return", "value"): {"build": form_return, "helpers": ""},
    ("composite-lit", "elem"): {"build": form_composite_lit, "helpers": ""},
    ("array-lit", "elem"): {"build": form_array_lit, "helpers": ""},
    ("mslice-lit", "elem"): {"build": form_mslice_lit, "helpers": ""},
    ("assign", "blank"): {"build": form_assign_blank, "helpers": ""},
    ("param", "arg"): {"build": form_param, "helpers": ""},
    ("multi-assign", "selector"): {"build": form_multi_assign_selector, "helpers": ""},
    ("multi-assign", "index-array"): {"build": form_multi_assign_index_array, "helpers": ""},
    ("multi-assign", "index-slice"): {"build": form_multi_assign_index_slice, "helpers": ""},
    ("multi-assign", "index-rawptr"): {"build": form_multi_assign_index_rawptr, "helpers": ""},
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
