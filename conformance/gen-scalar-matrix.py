#!/usr/bin/env python3
"""Generate conformance/matrix/scalar cells — sub-word & 64-on-32 scalar VALUE
correctness.

Three op-categories, each a different way a backend can get a scalar value
wrong, all asserting the target-independent correct result:

  - arithmetic (add/sub/mul): the op's true result OVERFLOWS the width and is
    consumed DIRECTLY by a width-sensitive right shift (no intermediate sized
    var to re-narrow). A backend that leaves dirty upper bits in the host
    register (the VM / natives) diverges; LLVM is correct. The 64-bit
    cells are a baseline (a uint64 IS the host word, so no narrowing needed).
  - div/rem: signed (sdiv/srem) vs unsigned (udiv/urem) dispatch on a value
    with the high bit set. (A regression net for a previously-fixed VM bug.)
  - int-to-float: an unsigned int with the top bit set converts to a large
    POSITIVE float; a backend that uses a SIGNED conversion reads it as
    negative. Only width 64 triggers it on a 64-bit host (a uint32 is
    zero-extended, hence positive); width 32 is the baseline.

Coordinate-addressed: conformance/matrix/scalar/<op>/<width>/<sign>.bn; the path
is the identity, so regeneration is idempotent and `.xfail.<mode>` markers
(maintained by hand) are never touched. Run:
`python3 conformance/gen-scalar-matrix.py [--check]`.

Python now; intended to port to Binate (dogfood) later — see ../matrix/README.md.
"""

import os
import sys

SCALAR_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "scalar")

WIDTHS = [8, 16, 32, 64]
SIGNS = ["unsigned", "signed"]
ARITH = {"add": "+", "sub": "-", "mul": "*"}
DIVREM = {"div": "/", "rem": "%"}
FLOAT_WIDTHS = [32, 64]

# Modes whose `int` is 32-bit (ILP32). `cast(int, <wide value>)` truncates /
# sign-reinterprets at 32 bits there, so a cell whose printed value differs from
# the LP64 (64-bit-int) value gets a per-mode `.expected.<mode>` override.
ILP32_MODES = ["builder-comp_arm32_linux", "builder-comp_arm32_baremetal"]


def cast_int(raw, width, signed, int_width):
    """The value `testing.Println(cast(int, v))` yields, where v is a width-bit value with
    two's-complement pattern `raw` (0 <= raw < 2^width) and the given signedness,
    cast to a signed `int` of int_width bits.  A source at least as wide as int
    truncates to the low int_width bits; a narrower source sign- or zero-extends
    per its signedness.  The result is then read as a signed int_width integer."""
    if width >= int_width:
        pat = raw & ((1 << int_width) - 1)
    elif signed and raw >= (1 << (width - 1)):
        pat = (raw - (1 << width)) & ((1 << int_width) - 1)
    else:
        pat = raw
    return pat - (1 << int_width) if pat >= (1 << (int_width - 1)) else pat


def typ(width, sign):
    return ("int" if sign == "signed" else "uint") + str(width)


def arith_cell(op, width, sign):
    m = 1 << width
    half = m >> 1
    shift = width // 2
    if sign == "unsigned":
        ab = {"add": (m - 64, m - 64),
              "mul": ((3 * (1 << (width // 2))) // 2,) * 2,
              "sub": (m // 4, (3 * m) // 4)}[op]
    else:
        ab = {"add": (half - 8, half - 8),
              "mul": ((3 * (1 << (width // 2))) // 2,) * 2,
              "sub": (-half + 4, 100)}[op]
    a, b = ab
    raw = {"add": a + b, "sub": a - b, "mul": a * b}[op]
    t = raw % m
    if sign == "signed" and t >= half:
        t -= m
    raw = (t >> shift) % (1 << width)
    signed = sign == "signed"
    body = [
        f"var a {typ(width, sign)} = {a}",
        f"var b {typ(width, sign)} = {b}",
        f"testing.Println(cast(int, (a {ARITH[op]} b) >> {shift}))",
    ]
    return body, [cast_int(raw, width, signed, 64)], [cast_int(raw, width, signed, 32)]


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def divrem_cell(op, width, sign):
    m = 1 << width
    half = m >> 1
    b = 7
    au = half + 13                      # high bit set
    a = au if sign == "unsigned" else au - m
    q = _trunc_div(a, b)
    correct = q if op == "div" else a - q * b
    raw = correct % (1 << width)
    signed = sign == "signed"
    body = [
        f"var a {typ(width, sign)} = {a}",
        f"var b {typ(width, sign)} = {b}",
        f"testing.Println(cast(int, a {DIVREM[op]} b))",
    ]
    return body, [cast_int(raw, width, signed, 64)], [cast_int(raw, width, signed, 32)]


def int_to_float_cell(width):
    y = 3 << (width - 2)                # top two bits set -> bit (width-1) set
    body = [
        f"var y uint{width} = {y}",
        "var f float64 = cast(float64, y)",
        "testing.Println(cast(int, f > 0.0))",  # 1 if the unsigned value -> positive float
    ]
    return body, [1], [1]


def float_to_int_cell(width):
    # Round-trip a high-bit-set unsigned through float64 and back.  The
    # int->float leg is already correct, so this isolates the float->uint
    # direction: a signed truncating convert (Fcvtzs / Cvttsd2si /
    # BC_FTOSI) mis-handles a float value >= 2^63.  width 32 stays exact
    # under either (the value is < 2^63); width 64 is the real defect.
    y = 3 << (width - 2)                # bit (width-1) set
    body = [
        f"var y uint{width} = {y}",
        "var f float64 = cast(float64, y)",
        f"var back uint{width} = cast(uint{width}, f)",
        "testing.Println(cast(int, back == y))",  # 1 if the round-trip is exact
    ]
    return body, [1], [1]


def shift_cell(op, width, sign):
    # Shift by a count >= the operand width. Per the spec (Go semantics):
    # `<<` / logical `>>` shift away to 0; arithmetic `>>` sign-fills. The bug
    # masks the count mod width, so count == width masks to 0 (identity): the
    # `1 << 64 == 1` / `full >> 64 == full` symptom. The count is a runtime
    # `var` (not a literal) so this exercises the backend shift, not the
    # const-fold path. CRITICAL — see claude-todo.md (shift-by->=-width).
    t = typ(width, sign)
    m = 1 << width
    count = width                       # canonical overshift (masks to 0)
    if op == "shl-overshift":
        x, expected, sym = 1, 0, "<<"   # 1 << width -> 0 (both signs)
    elif sign == "unsigned":
        x, expected, sym = m - 1, 0, ">>"   # logical >>: max >> width -> 0
    else:
        x, expected, sym = -(m >> 1), -1, ">>"  # arithmetic >>: min >> width -> -1
    body = [
        f"var x {t} = {x}",
        f"var c {t} = {count}",   # Binate ties the shift count's type to the operand's
        f"testing.Println(cast(int, x {sym} c))",
    ]
    return body, [expected], [expected]


SHIFTS = ["shl-overshift", "shr-overshift"]


HEADER = """package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-scalar-matrix.py — do not edit by hand.
// Scalar matrix cell — op={op}, width={width}, sign={sign}.
// Value correctness for a sub-word / conversion scalar op. See
// ../../../README.md.

"""


def render_bn(op, width, sign, body):
    out = HEADER.format(op=op, width=width, sign=sign)
    out += "func main() {\n"
    for ln in body:
        out += "\t" + ln + "\n"
    out += "}\n"
    return out


def fmt_expected(values):
    return "".join(str(x) + "\n" for x in values)


def all_cells():
    """Yield (op, width, sign, body, exp64, exp32) for every cell.  exp64 is the
    LP64 (`.expected`) value list; exp32 is the ILP32 (arm32) list — identical to
    exp64 except where `cast(int, …)` truncates / sign-reinterprets a wide value
    at 32-bit `int`."""
    for op in ARITH:
        for width in WIDTHS:
            for sign in SIGNS:
                body, e64, e32 = arith_cell(op, width, sign)
                yield op, width, sign, body, e64, e32
    for op in DIVREM:
        for width in WIDTHS:
            for sign in SIGNS:
                body, e64, e32 = divrem_cell(op, width, sign)
                yield op, width, sign, body, e64, e32
    for width in FLOAT_WIDTHS:
        body, e64, e32 = int_to_float_cell(width)
        yield "int-to-float", width, "unsigned", body, e64, e32
    for width in FLOAT_WIDTHS:
        body, e64, e32 = float_to_int_cell(width)
        yield "float-to-int", width, "unsigned", body, e64, e32
    for op in SHIFTS:
        for width in WIDTHS:
            for sign in SIGNS:
                body, e64, e32 = shift_cell(op, width, sign)
                yield op, width, sign, body, e64, e32


def _sync(path, content, changed, check):
    """Reconcile `path` to `content`; `content is None` means it must not exist.
    Records the relpath in `changed` when the on-disk state differs (for --check)."""
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if content is None:
        if old is not None:
            changed.append(os.path.relpath(path, os.path.dirname(SCALAR_DIR)))
            if not check:
                os.remove(path)
        return
    if old != content:
        changed.append(os.path.relpath(path, os.path.dirname(SCALAR_DIR)))
        if not check:
            with open(path, "w") as f:
                f.write(content)


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n = 0
    for op, width, sign, body, e64, e32 in all_cells():
        n += 1
        bn = render_bn(op, width, sign, body)
        exp64 = fmt_expected(e64)
        exp32 = fmt_expected(e32)
        d = os.path.join(SCALAR_DIR, op, str(width))
        os.makedirs(d, exist_ok=True)
        base = os.path.join(d, sign)
        _sync(base + ".bn", bn, changed, check)
        _sync(base + ".expected", exp64, changed, check)
        # An ILP32 (arm32) override only where the 32-bit `int` print differs;
        # otherwise ensure no stale override lingers.
        override = exp32 if exp32 != exp64 else None
        for mode in ILP32_MODES:
            _sync(base + ".expected." + mode, override, changed, check)
    if check:
        if changed:
            print("scalar matrix out of date (run conformance/gen-scalar-matrix.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("scalar matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print(f"{n} cells")
    return 0


if __name__ == "__main__":
    sys.exit(main())
