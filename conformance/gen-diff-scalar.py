#!/usr/bin/env python3
"""Generate conformance/matrix/scalar-diff — a property-based DIFFERENTIAL
value-correctness harness for scalar SHIFTS and CONVERSIONS (see
explorations/plan-differential-testing.md).

How it differs from the curated `matrix/scalar` cells: those test a handful of
hand-picked values per op (and so miss bugs at values nobody wrote — the
shift-by->=-width CRITICAL hid for exactly that reason). This generator emits a
*fixed, seeded* value set per coordinate — all the type/op boundaries plus a
deterministic pseudo-random sample — so a whole region of the input space is
swept, not a point.

The oracle is the **spec**, computed here at full precision (claude-notes
"Operators" / "Type conversions"), NOT a backend. So a value wrong on *every*
backend (a spec-divergence, the shift-bug class) is caught too: every backend
fails the cell vs the reference. (An LLVM-as-oracle differential would miss it.)

Self-checking, for target-stability: each tuple computes the op at runtime
(operands in `var`s, so the BACKEND op runs, not const-fold) and prints
`cast(int, (computed == spec_expected))` -> `1`. The comparison happens at the
operand width in-language; only a 0/1 reaches `println`, so a 64-bit result
never truncates through `cast(int, ...)` on a 32-bit target, and a sub-word
value never hits the native sub-word print path. Every `.expected` is therefore
a column of `1`s; a `0` on line N means tuple N (commented in the .bn) diverged.

DELIBERATELY EXCLUDED (spec says "hardware semantics" -> target-dependent, so
there is no single target-stable expected to assert; documented, not guessed):
  - out-of-range float->int, and NaN/+-Inf -> int;
  - f64->f32 narrowing except a few exactly-determined round-to-nearest cases.
These want a per-target expected or a spec decision; see the README.

Coordinate-addressed (path = identity -> idempotent regeneration; `.xfail.<mode>`
markers are hand-maintained and never touched):

  matrix/scalar-diff/shl/<width>/<sign>.bn          left shift
  matrix/scalar-diff/shr/<width>/<sign>.bn          right shift (arith if signed)
  matrix/scalar-diff/int-to-float/<width>/<sign>.bn int -> float32/float64
  matrix/scalar-diff/float-to-int/<width>/<sign>.bn float32/float64 -> int (in-range)
  matrix/scalar-diff/int-cast/<width>/<sign>.bn     int -> every int type
  matrix/scalar-diff/float-cast/roundtrip.bn        float32 <-> float64

Run: `python3 conformance/gen-diff-scalar.py [--check]`. Python now; intended to
port to Binate (dogfood) later — see ../matrix/README.md.
"""

import os
import sys

DIFF_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "matrix", "scalar-diff")

WIDTHS = [8, 16, 32, 64]
SIGNS = ["unsigned", "signed"]
FLOATS = [32, 64]
MANT = {32: 24, 64: 53}                 # significand bits (exact-int threshold)


def typ(width, sign):
    return ("int" if sign == "signed" else "uint") + str(width)


# --- two's-complement spec helpers (the oracle) -------------------------------

def uval(v, w):
    """Unsigned (bit-pattern) representation of math value v at width w."""
    return v & ((1 << w) - 1)


def sval(v, w):
    """Signed math value of the width-w bit pattern of v."""
    u = uval(v, w)
    return u - (1 << w) if u >= (1 << (w - 1)) else u


def reinterp(u, w, sign):
    """Typed math value of unsigned bit pattern u at width w under `sign`."""
    return sval(u, w) if sign == "signed" else u


def cast_expected(v, sw, ssign, dw, dsign):
    """`cast(<dw,dsign>, v)` where v has type <sw,ssign>: value-preserving wrap
    (claude-notes 452). The source math value reduced mod 2^dw, reinterpreted."""
    return reinterp(uval(v, dw), dw, dsign)


def shl_expected(x, c, w, sign):
    u = uval(uval(x, w) << c, w) if c < w else 0
    return reinterp(u, w, sign)


def shr_expected(x, c, w, sign):
    if sign == "unsigned":
        return (uval(x, w) >> c) if c < w else 0
    # arithmetic >>: Python's >> on a signed int sign-fills, and for c >= w
    # yields -1 (negative) / 0 (non-negative) — exactly the spec sign-fill.
    return sval(x, w) >> c


# --- deterministic PRNG (stable across runs/Python versions => idempotent) -----

class LCG:
    """A fixed 64-bit LCG. Seeded per-coordinate from a stable FNV-1a fold of
    the coordinate strings, so the sample is reproducible — no Math.random,
    regeneration is byte-identical."""

    def __init__(self, *parts):
        h = 1469598103934665603
        for p in parts:
            for ch in str(p):
                h = ((h ^ ord(ch)) * 1099511628211) & ((1 << 64) - 1)
        self.s = h

    def _next(self):
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return self.s >> 16

    def below(self, n):
        return self._next() % n

    def in_range(self, lo, hi):                 # inclusive
        return lo + self.below(hi - lo + 1)


def dedup(xs):
    return list(dict.fromkeys(xs))


# --- cell builder -------------------------------------------------------------

class Cell:
    """Accumulates self-checking tuples. Each `.check()` appends its setup
    statements and a `println(cast(int, <bool>))`; the matching `.expected`
    line is always `1`."""

    def __init__(self):
        self.lines = []
        self.n = 0

    def check(self, stmts, boolean, comment):
        i = self.n
        for s in stmts:
            self.lines.append(s.format(i=i))
        self.lines.append(
            "\tprintln(cast(int, {b}))\t// {c}".format(
                b=boolean.format(i=i), c=comment))
        self.n += 1


HEADER = '''package "main"

// GENERATED by conformance/gen-diff-scalar.py — do not edit by hand.
// Differential scalar value-correctness cell — {title}.
// Oracle is the spec; each line prints 1 iff the backend op matches it.
// See ../../../README.md and plan-differential-testing.md.

'''


def render(title, cell):
    out = HEADER.format(title=title)
    out += "func main() {\n"
    out += "\n".join(cell.lines) + "\n"
    out += "}\n"
    return out, "1\n" * cell.n


# --- shift cells --------------------------------------------------------------

def shift_operands(w, sign, rng):
    if sign == "unsigned":
        vs = [0, 1, (1 << w) - 1, 1 << (w - 1), (1 << (w - 1)) - 1,
              rng.below(1 << w)]
    else:
        vs = [0, 1, -1, (1 << (w - 1)) - 1, -(1 << (w - 1)),
              rng.in_range(-(1 << (w - 1)), (1 << (w - 1)) - 1)]
    return dedup(vs)


def shift_counts(w, rng):
    return dedup([0, 1, w // 2, w - 1, w, w + 1, w + 2, 2 * w, 2 * w + 3,
                  rng.below(2 * w + 1)])


def shift_cell(op, w, sign):
    rng = LCG(op, w, sign)
    t = typ(w, sign)
    sym = "<<" if op == "shl" else ">>"
    fn = shl_expected if op == "shl" else shr_expected
    cell = Cell()
    for c in shift_counts(w, rng):
        for x in shift_operands(w, sign, rng):
            e = fn(x, c, w, sign)
            stmts = ["\tvar x{i} %s = %d" % (t, x),
                     "\tvar c{i} %s = %d" % (t, c),
                     "\tvar e{i} %s = %d" % (t, e)]
            cell.check(stmts, "(x{i} %s c{i}) == e{i}" % sym,
                       "%s %s %d -> %d" % (x, sym, c, e))
    return cell


# --- int -> float cells -------------------------------------------------------

def itf_operands(w, sign, rng):
    if sign == "unsigned":
        vs = [0, 1, (1 << w) - 1, 1 << (w - 1), (1 << (w - 1)) + 1,
              rng.below(1 << w)]
    else:
        vs = [0, 1, -1, (1 << (w - 1)) - 1, -(1 << (w - 1)),
              rng.in_range(-(1 << (w - 1)), (1 << (w - 1)) - 1)]
    return dedup(vs)


def int_to_float_cell(w, sign):
    rng = LCG("itf", w, sign)
    t = typ(w, sign)
    cell = Cell()
    for v in itf_operands(w, sign, rng):
        for fw in FLOATS:
            f = "float%d" % fw
            # ordering: a correct convert keeps the sign (the unsigned
            # high-bit-set value must become a large POSITIVE float).
            rel = ">" if v > 0 else ("<" if v < 0 else "==")
            cell.check(
                ["\tvar v{i} %s = %d" % (t, v),
                 "\tvar f{i} %s = cast(%s, v{i})" % (f, f)],
                "f{i} %s 0.0" % rel,
                "sign cast(%s,%d) %s 0" % (f, v, rel))
            # round-trip, only where v is exactly representable in this float.
            if abs(v) < (1 << MANT[fw]):
                cell.check(
                    ["\tvar v{i} %s = %d" % (t, v),
                     "\tvar f{i} %s = cast(%s, v{i})" % (f, f),
                     "\tvar b{i} %s = cast(%s, f{i})" % (t, t)],
                    "b{i} == v{i}",
                    "roundtrip %d via %s" % (v, f))
    return cell


# --- float -> int cells (in-range only) ---------------------------------------

# Exact binary fractions (so `var f F = L` is exact on every target) whose
# truncation-toward-zero is unambiguous. Magnitudes stay < 128 so they fit
# every width incl. int8.
TRUNC_LITERALS = [0.0, 0.5, 1.5, 2.5, 3.75, 7.25, 15.5, 100.0]


def trunc_toward_zero(x):
    return int(x)                       # Python int() truncates toward zero


def float_to_int_cell(w, sign):
    t = typ(w, sign)
    cell = Cell()
    for fw in FLOATS:
        f = "float%d" % fw
        for mag in TRUNC_LITERALS:
            vals = [mag] if sign == "unsigned" else dedup([mag, -mag])
            for L in vals:
                e = trunc_toward_zero(L)
                cell.check(
                    ["\tvar f{i} %s = %s" % (f, fmt_float(L)),
                     "\tvar n{i} %s = cast(%s, f{i})" % (t, t),
                     "\tvar e{i} %s = %d" % (t, e)],
                    "n{i} == e{i}",
                    "trunc %s(%s) -> %d" % (f, fmt_float(L), e))
    # High-bit-set round-trip: 2^(w-1) is a single bit -> exact in any float.
    # For unsigned dest this is the in-range >= 2^63 case the signed-convert
    # bug (fptosi for an unsigned target) gets wrong. For signed dest the
    # corresponding exact case is the min value -2^(w-1).
    for fw in FLOATS:
        f = "float%d" % fw
        y = (1 << (w - 1)) if sign == "unsigned" else -(1 << (w - 1))
        cell.check(
            ["\tvar y{i} %s = %d" % (t, y),
             "\tvar f{i} %s = cast(%s, y{i})" % (f, f),
             "\tvar b{i} %s = cast(%s, f{i})" % (t, t)],
            "b{i} == y{i}",
            "highbit roundtrip %d via %s" % (y, f))
    return cell


def fmt_float(x):
    """Render a float literal Binate will parse to the exact IEEE value."""
    if x == int(x):
        return "%d.0" % int(x)
    return repr(x)


# --- int -> int cast cells ----------------------------------------------------

def cast_operands(w, sign, rng):
    if sign == "unsigned":
        vs = [0, 1, (1 << w) - 1, 1 << (w - 1), (1 << (w - 1)) - 1,
              rng.below(1 << w)]
    else:
        vs = [0, 1, -1, (1 << (w - 1)) - 1, -(1 << (w - 1)),
              rng.in_range(-(1 << (w - 1)), (1 << (w - 1)) - 1)]
    return dedup(vs)


def int_cast_cell(w, sign):
    rng = LCG("cast", w, sign)
    t = typ(w, sign)
    cell = Cell()
    for v in cast_operands(w, sign, rng):
        for dw in WIDTHS:
            for dsign in SIGNS:
                dt = typ(dw, dsign)
                e = cast_expected(v, w, sign, dw, dsign)
                cell.check(
                    ["\tvar v{i} %s = %d" % (t, v),
                     "\tvar n{i} %s = cast(%s, v{i})" % (dt, dt),
                     "\tvar e{i} %s = %d" % (dt, e)],
                    "n{i} == e{i}",
                    "cast(%s, %d:%s) -> %d" % (dt, v, t, e))
    return cell


# --- float32 <-> float64 cells ------------------------------------------------

def float_cast_cell():
    cell = Cell()
    # f32 -> f64 widening is exact: an int small enough for f32 round-trips
    # through f32 then f64 then back.
    for v in [0, 1, -1, 100, -100, (1 << 23) - 1, -(1 << 23)]:
        cell.check(
            ["\tvar v{i} int32 = %d" % v,
             "\tvar a{i} float32 = cast(float32, v{i})",
             "\tvar b{i} float64 = cast(float64, a{i})",
             "\tvar c{i} int32 = cast(int32, b{i})"],
            "c{i} == v{i}",
            "int32->f32->f64->int32 %d" % v)
    # f64 -> f32 narrowing rounds to nearest-even. 2^24+1 is not representable
    # in f32 and rounds to 2^24; 2^24+3 rounds to 2^24+4.
    for src, want in [((1 << 24) + 1, 1 << 24), ((1 << 24) + 3, (1 << 24) + 4)]:
        cell.check(
            ["\tvar v{i} int64 = %d" % src,
             "\tvar d{i} float64 = cast(float64, v{i})",
             "\tvar a{i} float32 = cast(float32, d{i})",
             "\tvar b{i} int64 = cast(int64, a{i})",
             "\tvar e{i} int64 = %d" % want],
            "b{i} == e{i}",
            "f64->f32 round %d -> %d" % (src, want))
    return cell


# --- driver -------------------------------------------------------------------

def all_cells():
    for op in ["shl", "shr"]:
        for w in WIDTHS:
            for sign in SIGNS:
                yield ("%s/%d/%s" % (op, w, sign),
                       "%s width=%d %s" % (op, w, sign),
                       shift_cell(op, w, sign))
    for w in WIDTHS:
        for sign in SIGNS:
            yield ("int-to-float/%d/%s" % (w, sign),
                   "int-to-float width=%d %s" % (w, sign),
                   int_to_float_cell(w, sign))
    for w in WIDTHS:
        for sign in SIGNS:
            yield ("float-to-int/%d/%s" % (w, sign),
                   "float-to-int width=%d %s" % (w, sign),
                   float_to_int_cell(w, sign))
    for w in WIDTHS:
        for sign in SIGNS:
            yield ("int-cast/%d/%s" % (w, sign),
                   "int-cast from width=%d %s" % (w, sign),
                   int_cast_cell(w, sign))
    yield ("float-cast/roundtrip", "float32<->float64 roundtrip",
           float_cast_cell())


def main():
    check = "--check" in sys.argv[1:]
    changed = []
    n_cells = n_tuples = 0
    for coord, title, cell in all_cells():
        n_cells += 1
        n_tuples += cell.n
        bn, expected = render(title, cell)
        path = os.path.join(DIFF_DIR, coord)
        d = os.path.dirname(path)
        if not check:
            os.makedirs(d, exist_ok=True)
        for ext, content in ((".bn", bn), (".expected", expected)):
            p = path + ext
            old = None
            if os.path.exists(p):
                with open(p) as fh:
                    old = fh.read()
            if old != content:
                changed.append(os.path.relpath(p, os.path.dirname(DIFF_DIR)))
                if not check:
                    with open(p, "w") as fh:
                        fh.write(content)
    if check:
        if changed:
            print("scalar-diff matrix out of date (run conformance/gen-diff-scalar.py):")
            for c in changed:
                print("  " + c)
            return 1
        print("scalar-diff matrix up to date")
        return 0
    for c in changed:
        print("wrote " + c)
    print("%d cells, %d tuples" % (n_cells, n_tuples))
    return 0


if __name__ == "__main__":
    sys.exit(main())
