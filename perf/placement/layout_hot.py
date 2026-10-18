"""layout.py --hot: per-function and per-loop overhead from the text output of
`perf report --stdio`.

perf credits each sample to the nearest symbol at or below its address, and
the native backends list their block labels (L<sym>__<blk>) and other local
labels in the symbol table, so a report on such a binary names blocks at least
as often as functions.  Every reported symbol is therefore resolved to its
address through the binary's own symbol table (a bare hex address, which perf
prints for a sample outside any symbol, is taken as is), and its overhead is
credited to the function whose extent holds that address and to every loop
whose footprint holds it.  A loop's figure is approximate: the samples of a
block without a label of its own go to the label before it, which may lie
outside the loop.

The Self column is used when the report has Children and Self columns
(`perf report --children`), else the Overhead column (the first one, the
group leader's, in a `--group` report); kernel ([k]) rows are skipped.  A
recording of several events reported without --group prints one table per
event, each adding up to 100%; only the first event's table is used, and its
name is reported.  A report with no row in the expected layout (overhead
first, then [.] / [k] and the symbol) is an error rather than 0%.  When the
report has a Shared Object column and some rows name the binary's file,
only those rows count, so that a library symbol that shares a name with one
of the binary's is not credited to it.  A name that resolves to
addresses in more than one function (a local label two objects both define)
is ambiguous and credited to none.

Python standard library only; the unit tests are in test_layout_hot.py.
"""

import bisect
import os
import re
from collections import Counter, namedtuple

Row = namedtuple("Row", "pct dso sym")

ROW_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)%\s+(?:(\d+(?:\.\d+)?)%\s+)?(.*?)\[(\S)\]\s+(\S+)")
ADDR_RE = re.compile(r"^0x([0-9a-fA-F]+)$")
EVENT_RE = re.compile(r"^# Samples: .* of events? '(.*)'")


def parse_perf(lines, name="the perf report"):
    """(rows, event) of a `perf report --stdio` text: rows (pct, dso, sym)
    of its first event's table, kernel rows dropped, dso None when the
    report has no Shared Object column; event names that event (None when
    the report does not say), noting how many the report holds.  Raises
    ValueError when no row is recognized."""
    rows, self_col, has_dso, events, event, seen = [], False, False, 0, None, 0
    for line in lines:
        if line.startswith("#"):
            m = EVENT_RE.match(line)
            if m:
                events += 1
                event = m.group(1) if events == 1 else event
            elif "Overhead" in line or "Children" in line:
                self_col = "Children" in line and "Self" in line
                has_dso = "Shared Object" in line
            continue
        m = ROW_RE.match(line)
        if not m or events > 1:
            continue
        seen += 1
        if m.group(4) == "k":
            continue
        pct = m.group(2) if self_col and m.group(2) else m.group(1)
        mid = m.group(3).split()
        dso = mid[-1] if has_dso and mid else None
        rows.append(Row(float(pct), dso, m.group(5)))
    if not seen:
        raise ValueError("%s: no sample row recognized (expected `perf report --stdio` "
                         "text with the overhead column first)" % name)
    if events > 1:
        event = "%s, the first of %d events" % (event, events)
    return rows, event


def _resolve(lay, sym):
    m = ADDR_RE.match(sym)
    if m:
        return [int(m.group(1), 16)]
    return lay.symaddrs.get(sym, [])


def apply_hot(lay, rows):
    """Set f.hot on lay's functions and lp["hot"] on their loops (None where
    no sample landed) from parse_perf rows; return the overhead totals by
    outcome: credited, ambiguous, unmatched (no function of the binary holds
    the symbol) and other_dso (rows of another file)."""
    funcs = sorted(lay.funcs, key=lambda f: f.addr)
    starts = [f.addr for f in funcs]

    def func_at(addr):
        i = bisect.bisect_right(starts, addr) - 1
        if i >= 0 and funcs[i].addr <= addr < max(funcs[i].span_end, funcs[i].addr + 1):
            return funcs[i]
        return None

    base = os.path.basename(lay.path)
    only_base = any(r.dso == base for r in rows)
    totals = Counter()
    for r in rows:
        if only_base and r.dso != base:
            totals["other_dso"] += r.pct
            continue
        addrs = _resolve(lay, r.sym)
        owners = {id(f): f for f in map(func_at, addrs) if f is not None}
        if not owners:
            totals["unmatched"] += r.pct
            continue
        if len(owners) > 1:
            totals["ambiguous"] += r.pct
            continue
        (f,) = owners.values()
        f.hot = (f.hot or 0.0) + r.pct
        totals["credited"] += r.pct
        for lp in f.loops:
            if any(s <= a < e for a in addrs for s, e in lp["_iv"]):
                lp["hot"] = (lp.get("hot") or 0.0) + r.pct
    return {k: round(totals.get(k, 0.0), 2)
            for k in ("credited", "ambiguous", "unmatched", "other_dso")}
