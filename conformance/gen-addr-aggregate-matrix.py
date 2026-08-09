#!/usr/bin/env python3
"""Generate conformance/matrix/addr-aggregate cells — 16-byte address-aggregate
(2-word) value handling (Class 2 of the code-red taxonomy; see claude-todo.md
TEST COVERAGE b1).

A managed interface value (`@Iface` = {data, vtable}) and a function value
(`@func` = {vtable, data}) are 16-byte 2-word "address aggregates". The recurring
bug class is a backend (esp. the VM) treating one as a single scalar word at an
arg-marshal / return-copy-back / store / extract site — dropping or swapping a
word, so a later dispatch hits a nil/garbage vtable (the VM func-value
nil-vtable, the 2-word-slice-len-drop neighborhood).

Assertion: **both words survive every operation** — observed by INVOKING the
value (call the func / call the iface method) after it crosses the boundary; a
dropped or swapped word yields a wrong result or a dispatch fault. Every cell
expects `42`.

Axes:  conformance/matrix/addr-aggregate/<kind>/<operation>.bn
  kind:      func-value (@func) · iface-value (@Iface)
  operation: direct · copy · return · arg · return-arg · field · array-elem ·
             global
             (where the value crosses: none / assignment / return-copy-back /
              arg-marshal / returned-then-passed / struct-field store+extract /
              array-element store+index / package-level global materialization)

Coordinate-addressed (path = identity); regeneration is idempotent and never
touches `.xfail.<mode>`. Run: `python3 conformance/gen-addr-aggregate-matrix.py`.
"""

import os
import sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "matrix", "addr-aggregate")

# Per-kind templates. invoke(expr) -> the int-returning invocation of `expr`.
FUNC = {
    "tname": "@func(int) int",
    "inline": "func(x int) int { return x + 41 }",
    "decls": (
        "func mkv() @func(int) int {\n"
        "\treturn func(x int) int { return x + 41 }\n}\n\n"
        "func takev(w @func(int) int) int {\n"
        "\treturn w(1)\n}\n\n"
        "type Holder struct {\n"
        "\tf @func(int) int\n}"),
    "invoke": lambda e: "%s(1)" % e,
}
IFACE = {
    "tname": "@Box",
    "inline": "make(B)",
    "decls": (
        "interface Box {\n\tget() int\n}\n\n"
        "type B struct {\n\tn int\n}\n\n"
        "func (b *B) get() int {\n\treturn 42\n}\n\n"
        "impl *B : Box\n\n"
        "func mkv() @Box {\n\treturn make(B)\n}\n\n"
        "func takev(w @Box) int {\n\treturn w.get()\n}\n\n"
        "type Holder struct {\n\tf @Box\n}"),
    "invoke": lambda e: "%s.get()" % e,
}
KINDS = [("func-value", FUNC), ("iface-value", IFACE)]


def body(k, op):
    """Return the main-body lines for (kind, operation)."""
    t = k["tname"]
    inl = k["inline"]
    inv = k["invoke"]
    if op == "direct":          # no boundary — construct inline, invoke
        return ["var v %s = %s" % (t, inl), "testing.Println(%s)" % inv("v")]
    if op == "copy":            # assignment copy of the 2-word value
        return ["var v %s = %s" % (t, inl), "var w %s = v" % t,
                "testing.Println(%s)" % inv("w")]
    if op == "return":          # produced by a returning func (return copy-back)
        return ["var v %s = mkv()" % t, "testing.Println(%s)" % inv("v")]
    if op == "arg":             # passed as an arg (arg-marshal)
        return ["var v %s = %s" % (t, inl), "testing.Println(takev(v))"]
    if op == "return-arg":      # returned value passed DIRECTLY as an arg
        return ["testing.Println(takev(mkv()))"]
    if op == "field":           # stored in a struct field, then extracted
        # Bind to a typed var first: a BARE func literal in a composite-literal
        # field doesn't infer its @func/*func flavour from the field type (a
        # separate, filed MINOR bug); this matrix tests 2-word survival, not
        # literal-flavour inference, so it stores an already-typed value.
        return ["var v %s = %s" % (t, inl),
                "var s Holder = Holder{f: v}", "testing.Println(%s)" % inv("s.f")]
    if op == "array-elem":      # stored in an array element, then indexed
        return ["var v %s = %s" % (t, inl), "var arr [1]%s" % t,
                "arr[0] = v", "testing.Println(%s)" % inv("arr[0]")]
    if op == "global":          # value lives in a package-level global var
        return ["testing.Println(%s)" % inv("gv")]
    raise ValueError(op)


def top_decl(k, op):
    """Extra top-level declarations beyond the kind's shared decls.  Only the
    `global` operation needs one: a package-level var of the 2-word type,
    initialized through the producer (mkv).  This exercises the backend's
    global-materialization path — the value is materialized into a package-level
    cell, stored there by `__init` (mkv's result), then read back and invoked.
    It pins that materialization / `__init`-store / read-back wiring, NOT storage
    sizing: the store and the load use the same width, so the cell round-trips
    consistently whatever allocation size the codegen picks.  Other operations
    keep the value in a local."""
    if op == "global":
        return "\n\nvar gv %s = mkv()" % k["tname"]
    return ""


OPERATIONS = ["direct", "copy", "return", "arg", "return-arg", "field",
              "array-elem", "global"]

HEADER = """package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-addr-aggregate-matrix.py — do not edit by hand.
// addr-aggregate matrix cell — kind={kind}, operation={op}.
// A 16-byte 2-word address-aggregate (@func / @Iface) must survive this
// operation with both words intact; invoking it must yield 42. A dropped/swapped
// word faults or returns wrong. See ../../README.md.

"""


def all_cells():
    for kind_name, k in KINDS:
        for op in OPERATIONS:
            yield (os.path.join(kind_name, op),
                   kind_name, op, k["decls"] + top_decl(k, op), body(k, op))


def render(kind_name, op, decls, lines):
    out = HEADER.format(kind=kind_name, op=op)
    out += decls + "\n\nfunc main() {\n"
    for ln in lines:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n = 0
    for rel, kind_name, op, decls, lines in all_cells():
        n += 1
        bn = render(kind_name, op, decls, lines)
        full = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", "42\n")):
            path = full + ext
            old = open(path).read() if os.path.exists(path) else None
            if old != content:
                changed.append(os.path.relpath(path, os.path.dirname(OUT)))
                if not check:
                    open(path, "w").write(content)
    if check:
        if changed:
            print("addr-aggregate matrix out of date:")
            for c in changed:
                print("  " + c)
            return 1
        print("addr-aggregate matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print("%d cells" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
