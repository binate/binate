"""Function extents for layout.py: cutting a section's items into spans at
function symbols, deciding which NOP runs are executed, trimming code a
function cannot reach, and reading the material that trails each span.

A span runs from one function symbol to the next.  Its trailing material is
the run of filler, NOPs, pad and gap items at its end: on x86-64 the last
part is the NOP pad that aligns the next entry, before that comes the
placement filler for the next function, and before that whatever the linker
put between two objects (NOPs, zeros, lld's 0xD4D4D4D4 on Arm, or lld's 0xCC
on x86-64, which merges with an INT3 filler run).

Python standard library only; the unit tests are in test_layout.py.
"""

from layout_disasm import CODE, FILL, NOP, PAD, GAP, FUNC, LABEL, OTHER

# Classes of the items a span's trailing material consists of.
TRAIL = (FILL, PAD, NOP, GAP)


class Span:
    """The items from one function symbol to the next, with the block labels
    and unclassified symbols inside them."""
    __slots__ = ("addr", "names", "recs", "labels", "others", "end")

    def __init__(self, addr, names):
        self.addr, self.names, self.recs = addr, names, []
        self.labels, self.others, self.end = [], [], addr


def cut_spans(recs, marks):
    """Split one section's items into spans at function symbols (the first
    span, before any function, has names None).  marks are (addr, order,
    role, name) in address order; mapping symbols only steer the
    disassembler and are dropped here."""
    cur, mi = Span(None, None), 0
    for r in recs:
        while mi < len(marks) and marks[mi][0] <= r.addr:
            addr, _, role, name = marks[mi]
            mi += 1
            if role == FUNC:
                if cur.names is not None and cur.addr == addr:
                    cur.names.append(name)
                    continue
                if cur.recs or cur.names is not None:
                    cur.end = addr
                    yield cur
                cur = Span(addr, [name])
            elif role == LABEL:
                cur.labels.append((addr, name))
            elif role == OTHER:
                cur.others.append((addr, name))
        if cur.addr is None:
            cur.addr = r.addr
        cur.recs.append(r)
    if cur.recs or cur.names is not None:
        cur.end = cur.recs[-1].end if cur.recs else cur.addr
        yield cur


def classify_nops(code, starts):
    """Turn each NOP run into PAD (alignment or dead padding) or CODE: a NOP
    run executed in straight-line code (reached by fall-through and followed
    by more code of the same block), or one that starts a block (a branch
    target or label in starts), which execution enters there."""
    i = 0
    while i < len(code):
        if code[i].cls != NOP:
            i += 1
            continue
        j = i
        while j < len(code) and code[j].cls == NOP:
            j += 1
        prev = code[i - 1] if i > 0 else None
        nxt = code[j] if j < len(code) else None
        inline = (prev is not None and prev.cls == CODE and prev.ft and nxt is not None
                  and nxt.cls == CODE and nxt.addr not in starts)
        entered = code[i].addr in starts
        for k in range(i, j):
            code[k].cls = CODE if inline or entered else PAD
        i = j


def owned_end(code, entry, own):
    """Index of the first code item after everything the function reaches:
    from its entry and its own block labels, along fall-through (across pad)
    and direct branches.  Code past that point has no symbol of its own (for
    instance a weak definition whose symbol the link bound to another
    object's copy) and is not attributed to the function."""
    index = {r.addr: i for i, r in enumerate(code) if r.cls == CODE}
    if entry not in index:
        return len(code)
    seen, work = set(), [index[entry]] + [index[a] for a in own if a in index]
    while work:
        i = work.pop()
        while i is not None and i not in seen:
            seen.add(i)
            r = code[i]
            if r.tgt is not None and not r.call and r.tgt in index:
                work.append(index[r.tgt])
            j = i + 1
            while j < len(code) and code[j].cls == PAD:
                j += 1
            i = j if r.ft and j < len(code) and code[j].cls == CODE else None
    for k in range(max(seen) + 1, len(code)):
        if code[k].cls == CODE:
            return k
    return len(code)


def trail_start(recs):
    """Index of the first item of recs' trailing material."""
    k = len(recs)
    while k > 0 and recs[k - 1].cls in TRAIL:
        k -= 1
    return k


class Tail:
    """The trailing material of a span, which ends at entry (where the next
    function symbol starts).  body_end is where the span's last other item
    ends (the span's start when it has none); pad is the NOP run directly
    before entry; fill the filler run directly before that pad, starting at
    start; last_fill_end the end of the last filler run anywhere in the
    material (None when there is none); prev the span's function (None for
    the items before a section's first function)."""
    __slots__ = ("body_end", "pad", "fill", "start", "entry", "last_fill_end", "prev")

    def __init__(self, recs, entry, prev=None):
        k, self.pad = len(recs), 0
        while k > 0 and recs[k - 1].cls in (PAD, NOP):
            k -= 1
            self.pad += recs[k].size
        self.fill = 0
        while k > 0 and recs[k - 1].cls == FILL:
            k -= 1
            self.fill += recs[k].size
        self.start = recs[k].addr if k < len(recs) else entry
        t = trail_start(recs)
        self.body_end = recs[t - 1].end if t > 0 else (recs[0].addr if recs else entry)
        fills = [r.end for r in recs[t:] if r.cls == FILL]
        self.last_fill_end = fills[-1] if fills else None
        self.entry, self.prev = entry, prev

    @property
    def gap(self):
        """Bytes between body_end and the filler run: the linker's fill
        between objects, or anything else that does not belong there."""
        return self.start - self.body_end
