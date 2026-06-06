#!/usr/bin/env python3
"""Generate conformance/matrix/const cells — compile-time constant
materialization (the constant-materialization class; see plan-code-red.md
§7.1b and the named-constant invariant in §5).

Assertion: a constant of a given type, appearing in a given syntactic position,
materializes to the EXACT bit pattern of its type. The discriminating axis is
the **read-form** (where the constant appears) — the front-end inserts the
width-narrowing coercion at some positions (var-init, typed const decl) but not
others (call-arg, composite-literal field, return), so an untyped float literal
can reach a typed slot un-narrowed. Float values also stress decimal->binary
rounding (float32 must round to float32, not a truncated float64); 64-bit values
stress multi-lane materialization (movz/movk on aa64, imm64 on x64, splitInt64
on ILP32).

Output is **target-stable**: every value is printed as its 16-bit little-endian
lanes via `cast(int, cast(uint16, <uintW>(x) >> 16*i))`, each lane in 0..65535,
so the single `.expected` matches on both ILP32 (`int`=32-bit) and LP64
(`int`=64-bit). The expected lanes are computed here from the exact IEEE-754 /
two's-complement bit pattern.

Coordinate-addressed:  conformance/matrix/const/<read-form>/<type>/<value>.bn
Path = identity; regeneration is idempotent and never touches `.xfail.<mode>`.
Run: `python3 conformance/gen-const-matrix.py [--check]`.
Python now; intended to port to Binate (dogfood) later — see ../matrix/README.md.
"""

import os
import struct
import sys

CONST_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "const")


# --- types: name -> (kind, width-bits) ---
# kind in {"int-s","int-u","float"}; width drives the lane count.
TYPES = {
    "uint8": ("int-u", 8),
    "int16": ("int-s", 16),
    "uint32": ("int-u", 32),
    "int64": ("int-s", 64),
    "uint64": ("int-u", 64),
    "float32": ("float", 32),
    "float64": ("float", 64),
}

# --- (type, value-label, source-literal) chosen to hit materialization edges. ---
VALUES = [
    ("uint8", "max", "255"),
    ("int16", "neg-one", "-1"),
    ("uint32", "max", "0xFFFFFFFF"),
    ("int64", "min", "-9223372036854775808"),
    ("int64", "multi-lane", "0x123456789ABCDEF0"),
    ("uint64", "max", "0xFFFFFFFFFFFFFFFF"),
    ("uint64", "high-bit", "0x8000000000000000"),
    ("float32", "tenth", "0.1"),       # f32 != truncated f64
    ("float32", "neg", "-0.1"),        # + sign through the narrow
    ("float32", "half", "0.5"),        # exactly representable
    ("float64", "tie", "1.0000000000000001110223024625156540424"),  # round-bit
    ("float64", "neg", "-0.1"),
]


def parse_int(lit):
    s = lit.strip()
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    v = int(s, 16) if s[:2].lower() == "0x" else int(s)
    return -v if neg else v


def bit_pattern(type_key, lit):
    """Exact unsigned bit pattern of `lit` materialized at `type_key`'s width."""
    kind, width = TYPES[type_key]
    if kind == "float":
        if width == 32:
            return struct.unpack("<I", struct.pack("<f", float(lit)))[0]
        return struct.unpack("<Q", struct.pack("<d", float(lit)))[0]
    return parse_int(lit) & ((1 << width) - 1)


def lanes(type_key, lit):
    """Expected 16-bit little-endian lanes (each 0..65535)."""
    _, width = TYPES[type_key]
    bits = bit_pattern(type_key, lit)
    n = 1 if width <= 16 else width // 16
    return [(bits >> (16 * i)) & 0xFFFF for i in range(n)]


def widen64(type_key, var):
    """A uint64 expression holding `var`'s bit pattern.

    Everything is reinterpreted/widened to uint64 so the per-lane `& 0xFFFF`
    masks at 64-bit width — a real mask the native backends honor. Extracting a
    lane with a sub-word reinterpret (`bit_cast(uint16, ...)`) instead would
    leave dirty upper bits in the register on native (the known sub-word
    narrowing gap) and misreport a wrong lane — that would conflate Class 5
    (scalar) with this constant-materialization (const) matrix.
    """
    kind, width = TYPES[type_key]
    if type_key == "float32":
        return f"cast(uint64, bit_cast(uint32, {var}))"   # 32-bit pattern, zero-ext
    if type_key == "float64":
        return f"bit_cast(uint64, {var})"
    if width == 64:
        return var if type_key == "uint64" else f"bit_cast(uint64, {var})"
    if kind == "int-u":
        return f"cast(uint64, {var})"                      # zero-extend
    return f"bit_cast(uint64, cast(int64, {var}))"         # sign-extend, reinterpret


def print_lanes(type_key, var):
    """Emit the lane-printing statements for `var` (16-bit LE lanes, masked)."""
    _, width = TYPES[type_key]
    u = widen64(type_key, var)
    nlanes = 1 if width <= 16 else width // 16
    out = []
    for i in range(nlanes):
        e = f"({u}) & 0xFFFF" if i == 0 else f"(({u}) >> {16 * i}) & 0xFFFF"
        out.append(f"println(cast(int, {e}))")
    return out


def zero_lit(type_key):
    return "0.0" if TYPES[type_key][0] == "float" else "0"


# --- read-forms: each yields (helper-decls, main-body-lines). The constant is
# observed via print_lanes on a value of the target type. ---
def rf_var_init(t, lit):
    return "", ["var x " + t + " = " + lit] + print_lanes(t, "x")


def rf_named_const(t, lit):
    return ("const C " + t + " = " + lit,
            ["var x " + t + " = C"] + print_lanes(t, "x"))


def rf_const_group(t, lit):
    helper = ("const (\n\tC0 " + t + " = " + lit
              + "\n\tC1 " + t + " = " + zero_lit(t) + "\n)")
    return helper, ["var x " + t + " = C0"] + print_lanes(t, "x")


def rf_local_const(t, lit):
    return "", (["const C " + t + " = " + lit, "var x " + t + " = C"]
                + print_lanes(t, "x"))


def rf_call_arg(t, lit):
    helper = ("func take(x " + t + ") {\n\t"
              + "\n\t".join(print_lanes(t, "x")) + "\n}")
    return helper, ["take(" + lit + ")"]


def rf_field(t, lit):
    helper = "type S struct {\n\tf " + t + "\n}"
    return helper, ["var s S = S{f: " + lit + "}"] + print_lanes(t, "s.f")


def rf_return(t, lit):
    helper = "func g() " + t + " {\n\treturn " + lit + "\n}"
    return helper, ["var x " + t + " = g()"] + print_lanes(t, "x")


READ_FORMS = [
    ("var-init", rf_var_init),
    ("named-const", rf_named_const),
    ("const-group", rf_const_group),
    ("local-const", rf_local_const),
    ("call-arg", rf_call_arg),
    ("field", rf_field),
    ("return", rf_return),
]


HEADER = """package "main"

// GENERATED by conformance/gen-const-matrix.py — do not edit by hand.
// const matrix cell — {desc}.
// The constant must materialize to the exact bit pattern of its type; printed
// as 16-bit little-endian lanes (target-stable). See ../../README.md and
// plan-code-red.md §7.1b.

"""


def all_cells():
    """Yield (relpath-without-ext, desc, helper, body, expected-lanes)."""
    for form_name, form_fn in READ_FORMS:
        for type_key, val_label, lit in VALUES:
            helper, body = form_fn(type_key, lit)
            rel = os.path.join(form_name, type_key, val_label)
            desc = (f"read-form={form_name}, type={type_key}, "
                    f"value={val_label} ({lit})")
            yield rel, desc, helper, body, lanes(type_key, lit)


def render(desc, helper, body):
    out = HEADER.format(desc=desc)
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
    n = 0
    for rel, desc, helper, body, expected in all_cells():
        n += 1
        bn = render(desc, helper, body)
        exp = "".join(str(x) + "\n" for x in expected)
        full = os.path.join(CONST_DIR, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", exp)):
            path = full + ext
            old = None
            if os.path.exists(path):
                with open(path) as f:
                    old = f.read()
            if old != content:
                changed.append(os.path.relpath(path, os.path.dirname(CONST_DIR)))
                if not check:
                    with open(path, "w") as f:
                        f.write(content)
    if check:
        if changed:
            print("const matrix out of date (run conformance/gen-const-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("const matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
