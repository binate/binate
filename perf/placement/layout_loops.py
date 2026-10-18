"""Control-flow graph, dominators and natural loops of one function, for
layout.py --loops.

The CFG is rebuilt from the disassembly.  The native backends emit no jump
tables, so every intra-function edge is a direct branch or a fall-through.
Blocks start at the function's entry points, at targets of its branches, at
block labels (L<sym>__<blk> and other local code labels), and after every
branch, return or trap; a call does not end a block.  Alignment pad (NOP runs
the caller classified PAD) belongs to no block, and fall-through crosses it;
data, filler and gap items end a block with no fall-through edge.

Dominators use the iterative algorithm of Cooper, Harvey and Kennedy from a
virtual root that reaches every entry point.  A natural loop is the header
plus every block that reaches a back edge's source (an edge whose target
dominates its source) without passing the header; loops sharing a header are
merged.  A loop's parent is the smallest other loop containing its header.

Loops are not contiguous in the native backends' output, so a loop's
footprint is the UNION of its member blocks' byte ranges; windows and lines
touched are counted over that union and compared with the minimum the same
bytes could occupy, ceil(bytes / size).  On x86-64 jcc counts the JCC-erratum
hit units inside the member blocks (layout.py adds jccw, the footprint's
32-byte windows any hit unit of the binary affects); on Arm, brden is the
loop's branches per 100 instructions and maxbr the most branches of its
member blocks in one window.
"""

import bisect
from collections import Counter

from layout_disasm import CODE, PAD


class Block:
    __slots__ = ("start", "end", "last", "succ", "pred", "insns", "branches",
                 "pad_before", "ft_in", "br_addrs")

    def __init__(self, start, pad_before, ft_in):
        self.start, self.end, self.last = start, start, None
        self.succ, self.pred, self.br_addrs = [], [], []
        self.insns = self.branches = 0
        self.pad_before, self.ft_in = pad_before, ft_in


def build_blocks(recs, entries, labels):
    """Basic blocks of a function's items (address order) and their edges."""
    code = {r.addr for r in recs if r.cls == CODE}
    starts = {a for a in entries if a in code} | {a for a in labels if a in code}
    for r in recs:
        if r.cls == CODE and r.tgt is not None and not r.call and r.tgt in code:
            starts.add(r.tgt)
    blocks, cur, brk = [], None, True
    pad_run, last = 0, None
    for r in recs:
        if r.cls == PAD:
            pad_run += r.size
            continue
        if r.cls != CODE:
            brk, last, pad_run = True, r, 0
            continue
        if brk or r.addr in starts:
            ft_in = last is not None and last.cls == CODE and last.ft
            b = Block(r.addr, pad_run, ft_in)
            if ft_in and cur is not None:
                cur.succ.append(len(blocks))
            blocks.append(b)
            cur = b
        cur.insns += 1
        if r.kind is not None:
            cur.branches += 1
            cur.br_addrs.append(r.addr)
        cur.end, cur.last = r.end, r
        brk = (r.kind is not None and not r.call) or not r.ft
        last, pad_run = r, 0
    index = {b.start: i for i, b in enumerate(blocks)}
    for b in blocks:
        t = b.last
        if t.tgt is not None and not t.call and t.tgt in index:
            if index[t.tgt] not in b.succ:
                b.succ.append(index[t.tgt])
    for i, b in enumerate(blocks):
        for s in b.succ:
            blocks[s].pred.append(i)
    return blocks


def dominators(blocks, roots):
    """idom per block (index; the virtual root is len(blocks)); None for a
    block no entry reaches."""
    n = len(blocks)
    vroot = n
    succ = [b.succ for b in blocks] + [sorted(set(roots))]
    post, seen, stack = [], [False] * (n + 1), [(vroot, 0)]
    seen[vroot] = True
    while stack:
        node, i = stack.pop()
        if i < len(succ[node]):
            stack.append((node, i + 1))
            nxt = succ[node][i]
            if not seen[nxt]:
                seen[nxt] = True
                stack.append((nxt, 0))
        else:
            post.append(node)
    rpo = post[::-1]
    order = {node: i for i, node in enumerate(rpo)}
    preds = [list(b.pred) for b in blocks] + [[]]
    for r in set(roots):
        preds[r].append(vroot)
    idom = [None] * (n + 1)
    idom[vroot] = vroot

    def meet(a, b):
        while a != b:
            while order[a] > order[b]:
                a = idom[a]
            while order[b] > order[a]:
                b = idom[b]
        return a

    changed = True
    while changed:
        changed = False
        for node in rpo[1:]:
            new = None
            for p in preds[node]:
                if idom[p] is not None:
                    new = p if new is None else meet(p, new)
            if new is not None and idom[node] != new:
                idom[node], changed = new, True
    return idom


def dominates(idom, h, u):
    vroot = len(idom) - 1
    while True:
        if u == h:
            return True
        if u == vroot or idom[u] is None:
            return False
        u = idom[u]


def natural_loops(blocks, idom):
    """{header index: set of member block indexes}."""
    loops = {}
    for u, b in enumerate(blocks):
        if idom[u] is None:
            continue
        for h in b.succ:
            if not dominates(idom, h, u):
                continue
            body = loops.setdefault(h, {h})
            stack = [u]
            while stack:
                x = stack.pop()
                if x in body:
                    continue
                body.add(x)
                stack.extend(p for p in blocks[x].pred if idom[p] is not None)
    return loops


def nest(loops):
    """{header: (parent header or None, depth, innermost)}."""
    by_size = sorted(loops, key=lambda h: (len(loops[h]), h))
    parent = {}
    for h in by_size:
        parent[h] = None
        for m in by_size:
            if m != h and h in loops[m] and len(loops[m]) > len(loops[h]):
                parent[h] = m
                break
    out = {}
    has_child = {p for p in parent.values() if p is not None}
    for h in loops:
        depth, p = 1, parent[h]
        while p is not None:
            depth, p = depth + 1, parent[p]
        out[h] = (parent[h], depth, h not in has_child)
    return out


def union(ranges):
    """Merged (start, end) intervals."""
    out = []
    for s, e in sorted(ranges):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def spans(intervals, size):
    """Distinct size-aligned windows the intervals touch."""
    idx = set()
    for s, e in intervals:
        idx.update(range(s // size, (e - 1) // size + 1))
    return len(idx)


def analyze(recs, entries, labels, window, line, hits=None):
    """Loop records for one function.  labels maps block-label addresses to
    names; hits lists the start addresses of erratum-hit units (None on an
    arch without the erratum, which gets brden and maxbr instead of jcc).
    pad is the alignment pad right before the header and pad_ft whether the
    code before that pad falls through into it (None when there is no pad);
    _iv holds the footprint's intervals, for use inside layout.py only."""
    blocks = build_blocks(recs, entries, labels)
    if not blocks:
        return []
    entry_set = set(entries)
    roots = [i for i, b in enumerate(blocks) if b.start in entry_set] or [0]
    idom = dominators(blocks, roots)
    loops = natural_loops(blocks, idom)
    tree = nest(loops)
    starts = [b.start for b in blocks]
    hit_blocks = {}
    for a in hits or ():
        i = bisect.bisect_right(starts, a) - 1
        if i >= 0 and a < blocks[i].end:
            hit_blocks[i] = hit_blocks.get(i, 0) + 1
    out = []
    for h in sorted(loops, key=lambda x: blocks[x].start):
        body = loops[h]
        hb = blocks[h]
        iv = union((blocks[i].start, blocks[i].end) for i in body)
        nbytes = sum(e - s for s, e in iv)
        insns = sum(blocks[i].insns for i in body)
        branches = sum(blocks[i].branches for i in body)
        parent, depth, inner = tree[h]
        lp = {"header": hb.start, "label": labels.get(hb.start, ""),
              "parent": blocks[parent].start if parent is not None else None,
              "depth": depth, "innermost": inner, "blocks": len(body),
              "insns": insns, "branches": branches,
              "bytes": nbytes, "ranges": len(iv),
              "hdr_m32": hb.start % 32, "hdr_m64": hb.start % 64,
              "windows": spans(iv, window), "windows_min": -(-nbytes // window),
              "lines": spans(iv, line), "lines_min": -(-nbytes // line),
              "pad": hb.pad_before, "pad_ft": hb.ft_in if hb.pad_before else None,
              "_iv": iv}
        if hits is None:
            per_win = Counter(a // window for i in body for a in blocks[i].br_addrs)
            lp["brden"] = round(100.0 * branches / insns, 1) if insns else 0.0
            lp["maxbr"] = max(per_win.values()) if per_win else 0
        else:
            lp["jcc"] = sum(hit_blocks.get(i, 0) for i in body)
        out.append(lp)
    return out
