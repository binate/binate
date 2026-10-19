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

A probed build (-fnative-place-probe=SYM -fnative-place-probe-phase=P, checked
with probe=(SYM, P)) puts SYM's first entry at phase P, at any seed and in
either mode, with filler before it as phase mode computes it and
PLACE_SPAN minus that filler right after its body.  SYM's row checks its
phase, and the filler run after it: the next row (when the next Binate
function's entry follows directly) expects that trailing filler before its
own, and otherwise the run before the next symbol must be exactly the
trailing filler (on Mach-O at least that long).  A probe that names no
function bnc places is reported by probe_row returning None.

An ELF link keeps every object's copy of a weak definition (a generic
instance, a helper several packages emit) but the symbol of only one, so
the others are unsymbolized code inside the extent of the function before
them, each with the filler bnc put around it (layout_span.pieces).  Without
a probe that changes nothing: the filler before the next function was
computed at the end of the last such copy, where its row looks.  With a
probe, an unsymbolized copy of SYM carries SYM's filler too.  So when such
code follows SYM's own body, SYM's trailing filler is the run that starts
right at the end of that body, followed by the leading filler of the next
function of its object (none at seed 0, below PLACE_SPAN otherwise; its
symbol is gone), and the next row does not expect SYM's trailing filler.
And a row after unsymbolized code from an object other than SYM's also
passes with a copy of SYM's trailing filler before its own when the last
piece of that code can be a copy of SYM: it starts at phase P after exactly
the filler SYM gets there, or an item of it other than its first starts at
phase P (a copy with no leading filler, so no filler run delimits it from
the code before it).  At a nonzero seed the run after SYM's body only has
bounds: the filler of the unsymbolized function after it, whose size its
missing symbol hides, can make up for a missing trailing filler.  And in
phase mode a row's own filler can absorb a copy's trailing filler, so no
copy may be needed to explain it.

On Mach-O a probe aligns .text to PLACE_SPAN even at seed 0, so after a
stripped atom ld64.lld may pad to the next atom's offset-implied alignment.
At seed 0 only SYM's row and the row after SYM take the relaxed rules above;
every other row passes when its filler is exact, or as "ok-gap" when the
only difference is such a linker gap with no filler at all in its trailing
material.  The row after SYM still needs a filler run of at least SYM's
trailing filler.

Unit tests: test_layout_seed.py, test_layout_probe.py,
test_layout_probe_copies.py and test_layout_formats.py (Mach-O).
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


def _row(lay, f, e, t, seed, mode, probe=None, post=0):
    """The check of function f, whose first entry is the function e and the
    trailing material before that entry t; post is the probed function's
    trailing filler expected at the start of t's filler run, after the
    probed function's own body or an unsymbolized copy of it (0 when
    none)."""
    unit, span = lay.unit, placehash.PLACE_SPAN
    first = maybe_first(t.prev)
    probed = placehash.is_probe(f.name, probe)
    want = post + placehash.fill_before(seed, mode, f.name, unit, t.body_end + post, probe)
    least = placehash.fill_before(seed, mode, f.name, unit, 0, probe) if first else None
    phi = (placehash.entry_phase(seed, f.name, unit, probe)
           if probed or (seed and mode == "phase") else None)
    phase_ok = phi is None or e.addr % span == phi
    follows = t.gap == 0 and t.fill == want and e.addr == _align(t.body_end + want, unit)
    starts = first and (least == 0 or t.pad == 0) and (e.addr - least) % unit == 0
    exact_first = starts and t.fill == least
    merged = (lay.rules.GAP_FILL_IS_FILLER and starts and t.fill > least and t.gap == 0
              and t.fill - least < span)
    fill_ok = follows or exact_first or merged
    if lay.fmt == "macho" and (seed or probed or post):
        if phi is None:
            ok, status = True, ("ok" if fill_ok else "inexact")
        elif phase_ok:
            ok, status = True, ("ok" if fill_ok else "ok-phase")
        else:
            end = t.last_fill_end if t.last_fill_end is not None else t.body_end
            point = _align(end, unit)
            ok = e is f and point % span == phi and point < e.addr
            status = "ok-fill" if ok else "FAIL"
    elif lay.fmt == "macho" and probe is not None and not fill_ok:
        # Seed 0 with a probe: no filler of ours, only a linker gap.
        ok = t.last_fill_end is None
        status = "ok-gap" if ok else "FAIL"
    else:
        ok = phase_ok and fill_ok
        status = ("ok" if follows or exact_first else "ok>=") if ok else "FAIL"
    row = {"name": f.name, "entry": e.addr, "entry_name": e.name,
            "phase": e.addr % span, "want_phase": phi,
            "dphase": None if phi is None else (e.addr - phi) % span,
            "fill": t.fill, "want_fill": want, "gap": t.gap, "pad": t.pad,
            "first": first, "least_fill": least, "parsed": f.pkg is not None,
            "probe": probed, "status": status, "ok": ok}
    settle = (t.start + t.fill, least) if merged and not (follows or exact_first) else None
    if probed:
        # The filler before the probed function as emitted: at its object's
        # start (where a linker gap may lengthen the run) the prediction for
        # object offset 0.
        row["pre"] = least if starts and not follows and (exact_first or merged) else want
    return row, settle


def _check_after_probe(lay, row, f, cover, seed):
    """Record the probed function's trailing filler as row['post'], and check
    the filler run right after the probed function f (row is its row) as
    row['after'] against row['want_after'].  When cover, the (row, Tail) of
    the next Binate function, already expected the probe's trailing filler in
    front of its own, that row's check stands (on Mach-O, where the row is
    relaxed, its last filler run must still hold at least the trailing
    filler).  When unsymbolized code follows f's body, the run starting right
    at that body's end is the trailing filler followed by the leading filler
    of the next function of f's object (see the module doc).  Otherwise the
    run before the next symbol is exactly PLACE_SPAN - row['pre'] (on Mach-O,
    where an atom after it may be stripped, at least that).  Returns the (run
    end, filler) the byte count may settle, or None."""
    span = placehash.PLACE_SPAN
    post = row["post"] = span - row["pre"]
    row["want_after"] = post
    after = lay.tails.get(f.span_end)
    settle = None
    if cover is not None:
        crow, ct = cover
        row["after"], row["want_after"] = crow["fill"], crow["want_fill"]
        last = lay.fill_runs.get(ct.last_fill_end, 0) if ct.last_fill_end is not None else 0
        ok = lay.fmt != "macho" or last >= post
    elif after is None or after.prev is not f:
        row["after"], ok = None, False
    elif after.pieces:
        run_start, run_len = after.pieces[0][:2]
        row["after"], row["after_code"] = run_len, True
        extra = run_len - post
        if run_start != f.end or extra < 0:
            ok = False
        elif lay.fmt == "macho":
            ok = True
        elif seed == 0:
            ok = extra == 0
        else:
            ok = extra < span and extra % lay.unit == 0
    else:
        row["after"] = after.fill
        ok = after.gap == 0 and (after.fill >= post if lay.fmt == "macho" else after.fill == post)
        settle = (after.start + after.fill, after.fill)
    if not ok:
        row["status"], row["ok"] = "FAIL", False
        return None
    return settle


def _copy_posts(lay, t, seed, mode, probe):
    """The trailing filler an unsymbolized copy of the probed function may
    have left right before t's filler run (t a Tail with pieces), as a list
    of candidates: PLACE_SPAN minus the filler before the last piece when
    that piece starts at the probe's phase after exactly the filler the probe
    gets there, and PLACE_SPAN (a copy whose leading filler was 0, so no
    filler run marks its start: it follows other unsymbolized code directly)
    when an item of the piece other than its first starts at the probe's
    phase.  None when there is no probe, or when the span's own function is
    the probed one: an object holds one copy of it."""
    if probe is None or not t.pieces or t.prev is None or placehash.is_probe(t.prev.name, probe):
        return []
    span, phi = placehash.PLACE_SPAN, probe[1]
    run_start, run_len, start, _, phases = t.pieces[-1]
    out = []
    if start % span == phi and run_len == placehash.fill_before(seed, mode, probe[0], lay.unit,
                                                                 run_start, probe):
        out.append(span - run_len)
    if phases >> phi & 1 and span not in out:
        out.append(span)
    return out


def _pick_row(lay, f, e, t, seed, mode, probe, posts):
    """_row for the first of posts (candidate probe trailing filler before
    t's own run) that passes it exactly, else for posts[0].  The row records
    as 'post_before' the candidate it used."""
    first = None
    for post in posts:
        row, settle = _row(lay, f, e, t, seed, mode, probe, post)
        row["post_before"] = post
        if row["ok"] and row["status"] != "inexact":
            return row, settle
        first = first or (row, settle)
    return first


def probe_row(rows):
    """The row of the probed function among expect_seed's rows, or None when
    the probe named no function that receives placement filler."""
    for r in rows:
        if r["probe"]:
            return r
    return None


def expect_seed(lay, seed, mode, probe=None):
    """One row per function of lay (a layout.Layout) that receives placement
    filler, for a build with the probe (SYM, PHASE) or None.  When every row
    passes, the rows that passed by the first-of-object rule with an INT3 run
    the linker's gap fill lengthened, and the probed function's trailing
    filler before a function that receives none, record their predicted
    filler in lay.known_fill, which settles lay.byte_counts' filler / gap
    split."""
    if probe is not None:
        placehash.check_probe(probe, lay.unit)
    rows, settles = [], []
    # Per row of the probed symbol: [its Func, its row, the (row, Tail) of the
    # function after it that expected its trailing filler, or None].
    probed = []
    for i, f in enumerate(lay.funcs):
        if not f.placed:
            continue
        e = lay.funcs[entry_index(lay, i)]
        t = lay.tails.get(e.addr) or Tail([], e.addr)
        # The probed function's trailing filler directly precedes this
        # entry's filler only when nothing unsymbolized lies in between.
        cover = None if t.pieces else next((p for p in probed if t.prev is p[0]), None)
        if cover is not None:
            posts = [placehash.PLACE_SPAN - cover[1]["pre"]]
        elif placehash.is_probe(f.name, probe):
            posts = [0]
        else:
            posts = [0] + _copy_posts(lay, t, seed, mode, probe)
        row, settle = _pick_row(lay, f, e, t, seed, mode, probe, posts)
        rows.append(row)
        if cover is not None:
            cover[2] = (row, t)
        if row["probe"]:
            probed.append([f, row, None])
        if settle is not None:
            settles.append(settle)
    for f, row, cover in probed:
        settle = _check_after_probe(lay, row, f, cover, seed)
        if settle is not None:
            settles.append(settle)
    inexact = [r for r in rows if r["status"] == "inexact"]
    if len(inexact) * 2 > len(rows):
        for r in inexact:
            r["status"], r["ok"] = "FAIL", False
    if rows and all(r["ok"] for r in rows):
        lay.known_fill.update(settles)
    return rows
