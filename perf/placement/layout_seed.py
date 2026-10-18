"""layout.py --expect-seed: check the function-placement filler of a seeded
build against placehash.py's prediction.

bnc's -fnative-place-seed=S puts trap-instruction filler before each Binate
function (keyed by its mangled symbol without object-format prefix) so that
the function's FIRST entry point (its first #[c_export] alias when it has
one) lands where placehash says.  The filler starts where the previous code
of the object ends, at object offset off, and is placehash.fill_before(off)
bytes; on x86-64 a NOP pad to the 16-byte entry alignment follows it.  So
for each Binate function this module finds that entry and the trailing
material before it (see layout_span.Tail), and checks that the filler run
starts exactly where the previous function's body ends, holds the bytes
fill_before gives for that offset, and puts the entry where the alignment
then does.  Phase mode also checks the entry's phase (shift mode predicts
none); dphase is how far the entry sits from the predicted phase, modulo
PLACE_SPAN.

The first function of an object starts the object's text, at an address
aligned to at least the filler unit, after whatever the linker put between
objects.  Which function is first is not visible in a linked binary, so a
function that may be first (one that does not follow another Binate
function directly) also passes when the filler run ends at its entry and
holds the filler fill_before gives at object offset 0.  lld fills the gap
between x86-64 objects with INT3, which merges with that run: there a longer
run passes as "ok>=" when it reaches back to the previous body's end, its
excess is less than PLACE_SPAN and leaves the object start unit-aligned.  No
linker fills with BRK / BKPT #0x5EED, so on Arm a longer run fails.  Filler
that is missing or replaced (by zeros, say) fails either way.

On Mach-O every symbol starts an atom the link may dead-strip.  The filler
before a function lies at the end of the atom before it (or, for an object's
first function, before any symbol), so stripping an atom removes the filler
of the function after it and leaves the stripped function's filler in front
of that function instead.  With a nonzero seed the filler count is therefore
not checked there (an unseeded build is checked as on ELF):
- phase mode checks the entry's phase.  That holds only when the linker
  keeps each atom's offset modulo the section alignment; a linker that aligns
  an atom only as far as its offset implies (ld64.lld does) moves the phase
  of every function after a stripped atom of its object, and those rows fail.
  A #[c_export] alias that only C code would call is an atom of its own and
  may be stripped too, leaving its function's mangled symbol after the
  alias's code length plus linker padding.  So a function found with no
  alias whose phase misses passes as "ok-fill" when the point its filler
  positions (the end of the last filler run before it, entry-aligned) has
  the predicted phase and lies before its symbol.
- shift mode marks a row whose filler differs "inexact" rather than failing
  it, and fails the run only when inexact rows outnumber exact ones: with
  the right seed only functions at an object start or after a stripped atom
  differ, while a wrong seed or an unseeded build matches about one row in
  PLACE_SPAN / unit.

Unit tests: test_layout_seed.py and test_layout_formats.py (Mach-O).
"""

import placehash
from layout_span import Tail


def entry_index(lay, i):
    """Index in lay.funcs of the function holding funcs[i]'s first entry
    point: the function itself, or a #[c_export] alias directly before it (a
    C name, not a bn_ symbol) whose code, a C-entry normalization or
    trampoline, transfers to it with no filler in between."""
    f = lay.funcs[i]
    if i > 0:
        p = lay.funcs[i - 1]
        tail = lay.tails.get(f.addr)
        if (p.sec == f.sec and p.span_end == f.addr and not p.placed and p.xfer_end
                and not p.cut and tail is not None and tail.fill == 0
                and not any(n.startswith("bn_") for n in p.names)):
            return i - 1
    return i


def maybe_first(prev):
    """Whether a function whose extent follows prev's may be the first of its
    object.  Each object the backends emit lists its Binate functions first
    and ends its text with synthesized code (shims, thunks, and always the
    package descriptor's __Package), so a Binate function directly after
    another is never first.  After anything else it may be (or may follow code
    whose weak symbol the link bound to another object's copy)."""
    return prev is None or prev.cut or not prev.placed


def _align(off, unit):
    return (off + unit - 1) // unit * unit


def _row(lay, f, e, t, seed, mode):
    """The check of function f, whose first entry is the function e and the
    trailing material before that entry t."""
    unit, span = lay.unit, placehash.PLACE_SPAN
    first = maybe_first(t.prev)
    want = placehash.fill_before(seed, mode, f.name, unit, t.body_end)
    least = placehash.fill_before(seed, mode, f.name, unit, 0) if first else None
    phi = placehash.entry_phase(seed, f.name, unit) if seed and mode == "phase" else None
    phase_ok = phi is None or e.addr % span == phi
    follows = t.gap == 0 and t.fill == want and e.addr == _align(t.body_end + want, unit)
    starts = first and (least == 0 or t.pad == 0) and (e.addr - least) % unit == 0
    exact_first = starts and t.fill == least
    merged = (lay.rules.GAP_FILL_IS_FILLER and starts and t.fill > least and t.gap == 0
              and t.fill - least < span)
    fill_ok = follows or exact_first or merged
    if lay.fmt == "macho" and seed:
        if mode != "phase":
            ok, status = True, ("ok" if fill_ok else "inexact")
        elif phase_ok:
            ok, status = True, ("ok" if fill_ok else "ok-phase")
        else:
            end = t.last_fill_end if t.last_fill_end is not None else t.body_end
            point = _align(end, unit)
            ok = e is f and point % span == phi and point < e.addr
            status = "ok-fill" if ok else "FAIL"
    else:
        ok = phase_ok and fill_ok
        status = ("ok" if follows or exact_first else "ok>=") if ok else "FAIL"
    row = {"name": f.name, "entry": e.addr, "entry_name": e.name,
            "phase": e.addr % span, "want_phase": phi,
            "dphase": None if phi is None else (e.addr - phi) % span,
            "fill": t.fill, "want_fill": want, "gap": t.gap, "pad": t.pad,
            "first": first, "least_fill": least, "parsed": f.pkg is not None,
            "status": status, "ok": ok}
    settle = (t.start + t.fill, least) if merged and not (follows or exact_first) else None
    return row, settle


def expect_seed(lay, seed, mode):
    """One row per function of lay (a layout.Layout) that receives placement
    filler.  When every row passes, the rows that passed by the
    first-of-object rule with an INT3 run the linker's gap fill lengthened
    record their predicted filler in lay.known_fill, which settles
    lay.byte_counts' filler / gap split."""
    rows, settles = [], []
    for i, f in enumerate(lay.funcs):
        if not f.placed:
            continue
        e = lay.funcs[entry_index(lay, i)]
        t = lay.tails.get(e.addr) or Tail([], e.addr)
        row, settle = _row(lay, f, e, t, seed, mode)
        rows.append(row)
        if settle is not None:
            settles.append(settle)
    inexact = [r for r in rows if r["status"] == "inexact"]
    if len(inexact) * 2 > len(rows):
        for r in inexact:
            r["status"], r["ok"] = "FAIL", False
    if rows and all(r["ok"] for r in rows):
        lay.known_fill.update(settles)
    return rows
