"""Tests for layout_loops.py: basic blocks, dominators, natural loops,
nesting and the union-footprint metrics, on hand-built item lists.

Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_loops as lp
from layout_disasm import CODE, PAD, FILL, DATA, Rec


def ins(addr, size=4, kind=None, tgt=None, ft=True, call=False):
    return Rec(addr, size, CODE, kind, ft, tgt, call)


def jcc(addr, tgt, size=4):
    return ins(addr, size, "jcc", tgt, True)


def jmp(addr, tgt, size=4):
    return ins(addr, size, "jmp", tgt, False)


def ret(addr):
    return ins(addr, 4, "ret", None, False)


def pad(addr, size):
    return Rec(addr, size, PAD)


def straight(start, end, size=4):
    return [ins(a, size) for a in range(start, end, size)]


def nested():
    """f: entry 0x0; outer loop header 0x10 (exit test), inner loop header
    0x20 whose body lives out of line at 0x60 (after the function's return),
    outer latch at 0x30.

        0x00 prologue           0x10 outer: jcc exit(0x40)
        0x14 jmp 0x20           0x20 inner: jcc 0x60 ; jmp 0x30
        0x30 latch; jmp 0x10    0x40 exit: ret
        0x44 pad to 0x60        0x60 inner body; jmp 0x20
    """
    return (straight(0x0, 0x10) + [jcc(0x10, 0x40), jmp(0x14, 0x20)] + [pad(0x18, 8)]
            + [jcc(0x20, 0x60), jmp(0x24, 0x30)] + [pad(0x28, 8)]
            + [ins(0x30), jmp(0x34, 0x10)] + [pad(0x38, 8)] + [ret(0x40)]
            + [Rec(0x44, 0x1C, FILL)] + straight(0x60, 0x6C) + [jmp(0x6C, 0x20)])


class BlockTest(unittest.TestCase):
    def test_blocks_and_edges(self):
        blocks = lp.build_blocks(nested(), [0x0], {})
        starts = [b.start for b in blocks]
        self.assertEqual(starts, [0x0, 0x10, 0x14, 0x20, 0x24, 0x30, 0x40, 0x60])
        succ = {blocks[i].start: sorted(blocks[j].start for j in b.succ)
                for i, b in enumerate(blocks)}
        self.assertEqual(succ[0x0], [0x10])
        self.assertEqual(succ[0x10], [0x14, 0x40])
        self.assertEqual(succ[0x14], [0x20])
        self.assertEqual(succ[0x20], [0x24, 0x60])
        self.assertEqual(succ[0x40], [])
        self.assertEqual(succ[0x60], [0x20])
        # pad before the inner header follows an unconditional jmp
        b20 = blocks[starts.index(0x20)]
        self.assertEqual((b20.pad_before, b20.ft_in), (8, False))

    def test_calls_do_not_end_blocks(self):
        recs = [ins(0x0), ins(0x4, 5, "call", 0x999, True, True), ins(0x9), ret(0xD)]
        blocks = lp.build_blocks(recs, [0x0], {})
        self.assertEqual([(b.start, b.insns, b.branches) for b in blocks], [(0x0, 4, 2)])

    def test_data_breaks_fallthrough(self):
        recs = [ins(0x0), jmp(0x4, 0x10), Rec(0x8, 8, DATA), ins(0x10), ret(0x14)]
        blocks = lp.build_blocks(recs, [0x0], {})
        self.assertEqual([b.start for b in blocks], [0x0, 0x10])
        self.assertFalse(blocks[1].ft_in)


class LoopTest(unittest.TestCase):
    def test_dominators(self):
        blocks = lp.build_blocks(nested(), [0x0], {})
        idom = lp.dominators(blocks, [0])
        start = {b.start: i for i, b in enumerate(blocks)}
        self.assertEqual(idom[start[0x10]], start[0x0])
        self.assertEqual(idom[start[0x60]], start[0x20])
        self.assertEqual(idom[start[0x30]], start[0x24])
        self.assertEqual(idom[start[0x40]], start[0x10])
        self.assertTrue(lp.dominates(idom, start[0x10], start[0x60]))
        self.assertFalse(lp.dominates(idom, start[0x60], start[0x30]))

    def test_nested_noncontiguous(self):
        labels = {0x20: "Lf__for.cond.2"}
        loops = lp.analyze(nested(), [0x0], labels, 32, 64)
        self.assertEqual([l["header"] for l in loops], [0x10, 0x20])
        outer, inner = loops
        self.assertEqual((outer["depth"], outer["innermost"], outer["blocks"]), (1, False, 6))
        self.assertEqual((inner["depth"], inner["innermost"], inner["blocks"]), (2, True, 2))
        self.assertEqual(inner["parent"], 0x10)
        self.assertEqual(inner["label"], "Lf__for.cond.2")
        # inner = header block [0x20,0x24) (the jmp at 0x24 leaves the loop)
        # + body [0x60,0x70): 20 bytes in two ranges, touching windows 1 and 3
        # of 32 bytes (minimum 1) and lines 0 and 1 (minimum 1).
        self.assertEqual((inner["bytes"], inner["ranges"]), (20, 2))
        self.assertEqual((inner["windows"], inner["windows_min"]), (2, 1))
        self.assertEqual((inner["lines"], inner["lines_min"]), (2, 1))
        self.assertEqual((inner["hdr_m32"], inner["hdr_m64"]), (0, 32))
        self.assertEqual((inner["insns"], inner["branches"]), (5, 2))
        self.assertEqual((inner["pad"], inner["pad_ft"]), (8, False))
        # outer: [0x10,0x18) [0x20,0x28) [0x30,0x38) [0x60,0x70)
        self.assertEqual((outer["bytes"], outer["ranges"]), (40, 4))

    def test_hits_counted_per_loop(self):
        loops = lp.analyze(nested(), [0x0], {}, 32, 64, hits=[0x24, 0x40, 0x6C])
        self.assertEqual([l["jcc"] for l in loops], [2, 1])
        self.assertFalse(any("brden" in l for l in loops))

    def test_branch_density_without_erratum(self):
        # inner loop: the jcc at 0x20 and the body's jmp at 0x6C, 2 branches
        # in 5 instructions, one per 16-byte window; the outer loop adds the
        # jmps at 0x14, 0x24 and 0x34 and the jcc at 0x10, so the windows at
        # 0x10 and 0x20 hold two branches each.
        loops = lp.analyze(nested(), [0x0], {}, 16, 64)
        outer, inner = loops
        self.assertEqual((inner["brden"], inner["maxbr"]), (40.0, 1))
        self.assertEqual((outer["branches"], outer["insns"]), (6, 10))
        self.assertEqual((outer["brden"], outer["maxbr"]), (60.0, 2))
        self.assertFalse(any("jcc" in l for l in loops))

    def test_fallthrough_pad(self):
        # loop header at 0x10 entered by falling through a 4-byte pad
        recs = [ins(0x0), ins(0x4), ins(0x8), pad(0xC, 4), ins(0x10), jcc(0x14, 0x10),
                ret(0x18)]
        loops = lp.analyze(recs, [0x0], {0x10: "L"}, 32, 64)
        self.assertEqual(len(loops), 1)
        self.assertEqual((loops[0]["pad"], loops[0]["pad_ft"]), (4, True))

    def test_window_phase(self):
        # a contiguous 0x5f-byte loop spans 3 windows at header phase 0 mod 32
        # and 4 at phase 16
        for base, want in ((0x1000, 3), (0x1010, 4)):
            body = [ins(base + i, 5) for i in range(0, 0x55, 5)] + [jcc(base + 0x55, base, 10)]
            recs = body + [ret(base + 0x5F)]
            loop = lp.analyze(recs, [base], {}, 32, 64)[0]
            self.assertEqual(loop["bytes"], 0x5F)
            self.assertEqual((loop["hdr_m32"], loop["windows"], loop["windows_min"]),
                             (base % 32, want, 3))

    def test_self_loop_and_unreachable(self):
        recs = [ins(0x0), jcc(0x4, 0x4), ret(0x8), ins(0xC), jmp(0x10, 0xC)]
        loops = lp.analyze(recs, [0x0], {}, 16, 64)
        self.assertEqual([(l["header"], l["blocks"]) for l in loops], [(0x4, 1)])

    def test_irreducible_has_no_natural_loop(self):
        # two entries into a cycle 0x10 <-> 0x20: neither dominates the other
        recs = [jcc(0x0, 0x20), jmp(0x4, 0x10), ins(0x10), jmp(0x14, 0x20),
                ins(0x20), jcc(0x24, 0x10), ret(0x28)]
        self.assertEqual(lp.analyze(recs, [0x0], {}, 32, 64), [])

    def test_union(self):
        self.assertEqual(lp.union([(10, 20), (0, 5), (15, 30), (30, 31)]),
                         [(0, 5), (10, 31)])
        self.assertEqual(lp.spans([(30, 34), (64, 65)], 32), 3)


if __name__ == "__main__":
    unittest.main()
