#!/usr/bin/env python3
"""Generate conformance/matrix/scalar-diff — a property-based DIFFERENTIAL
value-correctness harness for scalar SHIFTS and CONVERSIONS.

How it differs from the curated `matrix/scalar` cells: those test a handful of
hand-picked values per op (and so miss bugs at values nobody wrote — the
shift-by->=-width CRITICAL hid for exactly that reason). This generator emits a
*fixed, seeded* value set per coordinate — all the type/op boundaries plus a
deterministic pseudo-random sample — so a whole region of the input space is
swept, not a point.

The oracle is the **spec**, computed here at full precision (the operator and
type-conversion semantics), NOT a backend. So a value wrong on *every*
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
  - f64->f32 narrowing except a few exactly-determined round-to-nearest cases;
  - signed div/rem of min by -1 (the quotient 2^(w-1) overflows the signed
    range): x86 `idiv` traps `#DE`, ARM `sdiv` wraps. (Plain division by zero
    is also never emitted — the spec makes it a runtime trap, not a value.)
These want a per-target expected or a spec decision; see the README.

Coordinate-addressed (path = identity -> idempotent regeneration; `.xfail.<mode>`
markers are hand-maintained and never touched):

  matrix/scalar-diff/shl/<width>/<sign>.bn          left shift
  matrix/scalar-diff/shr/<width>/<sign>.bn          right shift (arith if signed)
  matrix/scalar-diff/int-to-float/<width>/<sign>.bn int -> float32/float64
  matrix/scalar-diff/float-to-int/<width>/<sign>.bn float32/float64 -> int (saturating)
  matrix/scalar-diff/int-cast/<width>/<sign>.bn     int -> every int type
  matrix/scalar-diff/float-cast/roundtrip.bn        float32 <-> float64
  matrix/scalar-diff/arith/<op>/<width>/<sign>.bn   add/sub/mul/div/rem
  matrix/scalar-diff/cmp/<width>/<sign>.bn          integer compares (6 relops)
  matrix/scalar-diff/fcmp/<floatwidth>.bn           float compares (NaN/Inf/-0)
  matrix/scalar-diff/bitwise/<op>/<width>/<sign>.bn and/or/xor/not

Run: `python3 conformance/gen-diff-scalar.py [--check]`. Python now; intended to
port to Binate (dogfood) later — see ../matrix/README.md.
"""

import math
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
    """`cast(<dw,dsign>, v)` where v has type <sw,ssign>: value-preserving wrap.
    The source math value reduced mod 2^dw, reinterpreted."""
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
    """Accumulates checks, each emitting one `testing.Println(cast(int, <expr>))`.

    - `.check(stmts, boolean, comment)` — a *self-checking* tuple: `boolean` is
      `computed == spec_expected`, so the printed line is `1` when the backend
      matches the spec (target-stable: only 0/1 is printed).
    - `.check_raw(stmts, expr, expected, comment)` — prints `cast(int, expr)`
      directly with an explicit `expected` (0/1). Used for comparisons, whose
      result already *is* the 0/1 output (a clean bool, so already
      target-stable) — and where seeing got-vs-want aids debugging.
    - `.preamble(stmts)` — shared setup emitted once before all tuples (e.g.
      the named NaN/Inf/-0.0 values reused across a float-compare cell).

    Each tuple's `{i}` placeholders are filled with its index so per-tuple var
    names don't collide; preamble statements use fixed names (no `{i}`)."""

    def __init__(self):
        self.pre = []
        self.lines = []
        self.exps = []

    def preamble(self, stmts):
        self.pre.extend(stmts)

    def check(self, stmts, boolean, comment):
        self._emit(stmts, boolean, comment, 1)

    def check_raw(self, stmts, expr, expected, comment):
        self._emit(stmts, expr, comment, expected)

    def _emit(self, stmts, expr, comment, expected):
        i = len(self.exps)
        for s in stmts:
            self.lines.append(s.format(i=i))
        self.lines.append(
            "\ttesting.Println(cast(int, {e}))\t// {c}".format(
                e=expr.format(i=i), c=comment))
        self.exps.append(expected)

    @property
    def n(self):
        return len(self.exps)


HEADER = '''package "main"

import "pkg/builtins/testing"

// GENERATED by conformance/gen-diff-scalar.py — do not edit by hand.
// Differential scalar value-correctness cell — {title}.
// Oracle is the spec; each line prints 1 iff the backend op matches it.
// See ../../../README.md.

'''


def render(title, cell):
    out = HEADER.format(title=title)
    out += "func main() {\n"
    if cell.pre:
        out += "\n".join(cell.pre) + "\n"
    out += "\n".join(cell.lines) + "\n"
    out += "}\n"
    return out, "".join("%d\n" % e for e in cell.exps)


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


def saturate_to_int(x, w, sign):
    """The spec oracle for float->int: in-range truncates toward zero; out of
    [MIN, MAX] (incl. +-Inf) saturates to that bound; NaN -> 0."""
    if sign == "unsigned":
        lo, hi = 0, (1 << w) - 1
    else:
        lo, hi = -(1 << (w - 1)), (1 << (w - 1)) - 1
    if math.isnan(x):
        return 0
    if math.isinf(x):
        return hi if x > 0 else lo
    t = int(x)                          # truncate toward zero (finite)
    if t < lo:
        return lo
    if t > hi:
        return hi
    return t


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
    # Saturation + NaN: out-of-range finite values, +-Inf, and NaN clamp to
    # [MIN, MAX] (NaN -> 0).  The thresholds 2^(w-1) / 2^w (and their doubles
    # / negations) are exact powers of two, so identical in float32 and
    # float64; +-Inf / NaN come from exact IEEE bit patterns.  -2^(w-1) for a
    # signed dest is MIN itself (in range) — pinning the `< MIN` strict
    # boundary.
    thr = (1 << (w - 1)) if sign == "signed" else (1 << w)
    if sign == "signed":
        finite = [thr, 2 * thr, -thr, -2 * thr]
    else:
        finite = [thr, 2 * thr, -1, -thr]
    for fw in FLOATS:
        f = "float%d" % fw
        ut = "uint%d" % fw
        for v in finite:
            e = saturate_to_int(float(v), w, sign)
            cell.check(
                ["\tvar f{i} %s = %s" % (f, fmt_float(float(v))),
                 "\tvar n{i} %s = cast(%s, f{i})" % (t, t),
                 "\tvar e{i} %s = %d" % (t, e)],
                "n{i} == e{i}",
                "saturate %s(%s) -> %d" % (f, fmt_float(float(v)), e))
        for name, bits, fv in FBITS[fw]:
            if name not in ("inf", "ninf", "nan"):
                continue
            e = saturate_to_int(fv, w, sign)
            cell.check(
                ["\tvar fb{i} %s = %d" % (ut, bits),
                 "\tvar f{i} %s = bit_cast(%s, fb{i})" % (f, f),
                 "\tvar n{i} %s = cast(%s, f{i})" % (t, t),
                 "\tvar e{i} %s = %d" % (t, e)],
                "n{i} == e{i}",
                "saturate %s(%s) -> %d" % (f, name, e))
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


# --- arithmetic cells (add/sub/mul/div/rem) -----------------------------------

ARITH_BIN = {"add": "+", "sub": "-", "mul": "*"}
DIVREM = {"div": "/", "rem": "%"}


def arith_wrap_expected(op, a, b, w, sign):
    raw = {"add": a + b, "sub": a - b, "mul": a * b}[op]
    return reinterp(uval(raw, w), w, sign)


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def divrem_expected(op, a, b, w, sign):
    q = _trunc_div(a, b)
    v = q if op == "div" else a - q * b
    return reinterp(uval(v, w), w, sign)


def arith_pairs(op, w, sign, rng):
    """Operand pairs. For add/sub/mul, pairs whose true result OVERFLOWS the
    width (so an un-narrowed result has dirty upper bits when consumed by a
    shift). For div/rem, b != 0, and for signed never the min/-1 overflow —
    that is target-dependent (x86 `idiv` traps `#DE`, ARM `sdiv` wraps), so it
    is EXCLUDED like out-of-range float->int (see the module docstring)."""
    half = 1 << (w // 2)
    if op in DIVREM:
        if sign == "unsigned":
            pairs = [((1 << (w - 1)) + 13, 7), ((1 << (w - 1)) + 13, 3),
                     ((1 << w) - 1, 2), (5, 7), (0, 9),
                     (rng.below(1 << w), rng.in_range(1, (1 << w) - 1))]
        else:
            mx, mn = (1 << (w - 1)) - 1, -(1 << (w - 1))
            pairs = [(mn + 13, 7), (mn + 13, -7), (-100, 7), (mx, -3), (7, 11),
                     (rng.in_range(mn, mx),
                      rng.in_range(1, mx) * (1 if rng.below(2) else -1))]
        out = []
        for a, b in pairs:
            if b == 0:
                continue
            if sign == "signed" and a == -(1 << (w - 1)) and b == -1:
                continue
            out.append((a, b))
        return out
    if sign == "unsigned":
        m = (1 << w) - 1
        return [(m, m), (m, 2), (1 << (w - 1), 1 << (w - 1)),
                (half + 5, half + 5), (m - 3, 9), (0, 0),
                (rng.below(1 << w), rng.below(1 << w))]
    mx, mn = (1 << (w - 1)) - 1, -(1 << (w - 1))
    return [(mx, mx), (mn, mn), (mx, 2), (mn, -3), (-half + 1, -half + 1),
            (mx, mn), (rng.in_range(mn, mx), rng.in_range(mn, mx))]


def arith_cell(op, w, sign):
    rng = LCG("arith", op, w, sign)
    t = typ(w, sign)
    half = w // 2
    cell = Cell()
    for a, b in arith_pairs(op, w, sign, rng):
        if op in ARITH_BIN:
            sym = ARITH_BIN[op]
            e = arith_wrap_expected(op, a, b, w, sign)
            base = ["\tvar a{i} %s = %d" % (t, a), "\tvar b{i} %s = %d" % (t, b)]
            cell.check(base + ["\tvar e{i} %s = %d" % (t, e)],
                       "(a{i} %s b{i}) == e{i}" % sym,
                       "%d %s %d -> %d" % (a, sym, b, e))
            # Consume the result through a width-sensitive shift: a backend that
            # leaves dirty upper bits (the VM/natives sub-word gap) diverges
            # here even though the direct compare above may re-narrow.
            es = shr_expected(e, half, w, sign)
            cell.check(base + ["\tvar s{i} %s = %d" % (t, es)],
                       "((a{i} %s b{i}) >> %d) == s{i}" % (sym, half),
                       "(%d %s %d)>>%d -> %d" % (a, sym, b, half, es))
        else:
            sym = DIVREM[op]
            e = divrem_expected(op, a, b, w, sign)
            cell.check(["\tvar a{i} %s = %d" % (t, a),
                        "\tvar b{i} %s = %d" % (t, b),
                        "\tvar e{i} %s = %d" % (t, e)],
                       "(a{i} %s b{i}) == e{i}" % sym,
                       "%d %s %d -> %d" % (a, sym, b, e))
    return cell


# --- comparison cells ---------------------------------------------------------

RELOPS = [("==", lambda a, b: a == b), ("!=", lambda a, b: a != b),
          ("<", lambda a, b: a < b), ("<=", lambda a, b: a <= b),
          (">", lambda a, b: a > b), (">=", lambda a, b: a >= b)]


def cmp_values(w, sign, rng):
    if sign == "unsigned":
        vs = [0, 1, (1 << w) - 1, 1 << (w - 1), (1 << (w - 1)) - 1,
              rng.below(1 << w)]
    else:
        vs = [0, 1, -1, (1 << (w - 1)) - 1, -(1 << (w - 1)),
              rng.in_range(-(1 << (w - 1)), (1 << (w - 1)) - 1)]
    return dedup(vs)


def cmp_cell(w, sign):
    """Integer comparisons across all six relops. Operands cross the high-bit
    boundary, where signed and unsigned disagree (a top-bit-set value is a large
    positive unsigned but a negative signed) — exposing a backend that picks the
    wrong signed/unsigned compare. The result IS the printed 0/1."""
    rng = LCG("cmp", w, sign)
    t = typ(w, sign)
    vs = cmp_values(w, sign, rng)
    cell = Cell()
    for a in vs:
        for b in vs:
            for sym, fn in RELOPS:
                res = 1 if fn(a, b) else 0
                cell.check_raw(
                    ["\tvar a{i} %s = %d" % (t, a), "\tvar b{i} %s = %d" % (t, b)],
                    "a{i} %s b{i}" % sym, res,
                    "%d %s %d -> %d" % (a, sym, b, res))
    return cell


# Named float values built by bit_cast from their exact IEEE bit patterns, so
# -0.0 / Inf / NaN are exact and literal-parse-independent. (uint bits, value.)
FBITS = {
    64: [("z", 0x0000000000000000, 0.0), ("nz", 0x8000000000000000, -0.0),
         ("one", 0x3FF0000000000000, 1.0), ("mone", 0xBFF0000000000000, -1.0),
         ("inf", 0x7FF0000000000000, math.inf),
         ("ninf", 0xFFF0000000000000, -math.inf),
         ("nan", 0x7FF8000000000000, math.nan)],
    32: [("z", 0x00000000, 0.0), ("nz", 0x80000000, -0.0),
         ("one", 0x3F800000, 1.0), ("mone", 0xBF800000, -1.0),
         ("inf", 0x7F800000, math.inf), ("ninf", 0xFF800000, -math.inf),
         ("nan", 0x7FC00000, math.nan)],
}


def fcmp_cell(fw):
    """Float comparisons across all six relops over {0, -0, +-1, +-Inf, NaN}.
    Pins the IEEE ordered/unordered semantics (`==` and the
    relationals are ordered -> false on NaN; `!=` is unordered -> true on NaN;
    `+0.0 == -0.0`). The `!=`-unordered rule was corrected 2026-06-06, so this
    guards a fresh fix. Python's float comparisons are IEEE, so they give the
    spec truth directly."""
    f = "float%d" % fw
    ut = "uint%d" % fw
    vals = FBITS[fw]
    cell = Cell()
    pre = []
    for name, bits, _ in vals:
        pre.append("\tvar %s_b %s = %d" % (name, ut, bits))
        pre.append("\tvar %s %s = bit_cast(%s, %s_b)" % (name, f, f, name))
    cell.preamble(pre)
    for an, _, av in vals:
        for bn, _, bv in vals:
            for sym, fn in RELOPS:
                res = 1 if fn(av, bv) else 0
                cell.check_raw([], "%s %s %s" % (an, sym, bn), res,
                               "%s %s %s -> %d" % (an, sym, bn, res))
    return cell


# --- bitwise cells (and/or/xor/not) -------------------------------------------

BITWISE = {"and": "&", "or": "|", "xor": "^"}


def bitwise_expected(op, a, b, w, sign):
    ua, ub = uval(a, w), uval(b, w)
    u = {"and": ua & ub, "or": ua | ub, "xor": ua ^ ub}[op]
    return reinterp(u, w, sign)


def bit_values(w, sign, rng):
    if sign == "unsigned":
        pat = int(("10" * ((w + 1) // 2))[:w], 2)
        vs = [0, 1, (1 << w) - 1, 1 << (w - 1), pat, rng.below(1 << w)]
    else:
        vs = [0, 1, -1, (1 << (w - 1)) - 1, -(1 << (w - 1)),
              rng.in_range(-(1 << (w - 1)), (1 << (w - 1)) - 1)]
    return dedup(vs)


def bitwise_cell(op, w, sign):
    rng = LCG("bit", op, w, sign)
    t = typ(w, sign)
    vs = bit_values(w, sign, rng)
    cell = Cell()
    if op == "not":
        half = w // 2
        for v in vs:
            e = reinterp(uval(~v, w), w, sign)
            cell.check(["\tvar v{i} %s = %d" % (t, v),
                        "\tvar e{i} %s = %d" % (t, e)],
                       "(~v{i}) == e{i}", "~%d -> %d" % (v, e))
            # `~` of a sub-word value overflows the width; consume via shift to
            # expose an un-narrowed (dirty-upper-bit) complement.
            es = shr_expected(e, half, w, sign)
            cell.check(["\tvar v{i} %s = %d" % (t, v),
                        "\tvar s{i} %s = %d" % (t, es)],
                       "((~v{i}) >> %d) == s{i}" % half,
                       "(~%d)>>%d -> %d" % (v, half, es))
        return cell
    sym = BITWISE[op]
    for a in vs:
        for b in vs:
            e = bitwise_expected(op, a, b, w, sign)
            cell.check(["\tvar a{i} %s = %d" % (t, a),
                        "\tvar b{i} %s = %d" % (t, b),
                        "\tvar e{i} %s = %d" % (t, e)],
                       "(a{i} %s b{i}) == e{i}" % sym,
                       "%d %s %d -> %d" % (a, sym, b, e))
    return cell


def neg_cell(w, sign):
    # Unary minus `-x` at the operand width: the result type must be the
    # operand's exact width, not host int (the analog of the `~` bug — see
    # bitnot/Defect-9 in claude-todo).  Each value is checked directly and,
    # like `~`, consumed through a `>> half` so an un-narrowed host-width
    # negation (dirty upper bits) is exposed rather than masked by a re-narrow.
    rng = LCG("neg", w, sign)
    t = typ(w, sign)
    vs = bit_values(w, sign, rng)
    cell = Cell()
    half = w // 2
    for v in vs:
        e = reinterp(uval(-v, w), w, sign)
        cell.check(["\tvar v{i} %s = %d" % (t, v),
                    "\tvar e{i} %s = %d" % (t, e)],
                   "(-v{i}) == e{i}", "-%d -> %d" % (v, e))
        es = shr_expected(e, half, w, sign)
        cell.check(["\tvar v{i} %s = %d" % (t, v),
                    "\tvar s{i} %s = %d" % (t, es)],
                   "((-v{i}) >> %d) == s{i}" % half,
                   "(-%d)>>%d -> %d" % (v, half, es))
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
    for op in list(ARITH_BIN) + list(DIVREM):
        for w in WIDTHS:
            for sign in SIGNS:
                yield ("arith/%s/%d/%s" % (op, w, sign),
                       "%s width=%d %s" % (op, w, sign),
                       arith_cell(op, w, sign))
    for w in WIDTHS:
        for sign in SIGNS:
            yield ("cmp/%d/%s" % (w, sign),
                   "integer compare width=%d %s" % (w, sign),
                   cmp_cell(w, sign))
    for fw in FLOATS:
        yield ("fcmp/%d" % fw, "float%d compare (NaN/Inf/-0)" % fw,
               fcmp_cell(fw))
    for op in list(BITWISE) + ["not"]:
        for w in WIDTHS:
            for sign in SIGNS:
                yield ("bitwise/%s/%d/%s" % (op, w, sign),
                       "%s width=%d %s" % (op, w, sign),
                       bitwise_cell(op, w, sign))
    for w in WIDTHS:
        for sign in SIGNS:
            yield ("neg/%d/%s" % (w, sign),
                   "unary minus width=%d %s" % (w, sign),
                   neg_cell(w, sign))


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
