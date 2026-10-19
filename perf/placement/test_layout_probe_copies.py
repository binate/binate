"""Tests for the probe in layout_seed.py where an ELF link left unsymbolized
copies of weak definitions (the copies whose symbol it bound to another
object's), each with the filler bnc put around it: after the probed
function's own body, as a copy of the probed function before another row
(its trailing filler delimited by its leading filler or, when that was 0,
not), and without a probe.  Also the seed-0 Mach-O rules of a probed build:
exact filler for every row but the probe's and the one after it, a linker
gap with no filler as "ok-gap", and the trailing filler the row after the
probe must still hold.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import placehash
from layout_testutil import Prog
from test_layout import load


def key(c):
    return "bn_F1_1_q1_1_%s" % c


# Live functions, the probed function P and the weak definitions whose copies
# the fixture leaves unsymbolized.
X, B, Y, C, P, D, Z, E = (key(c) for c in "xbycpdze")
W1, W2, V = "bn_I1_1_q1_w1_N0_3_int", "bn_I1_1_q1_w2_N0_3_int", "bn_I1_1_q1_v_N0_3_int"

INSNS = {"x86_64": ((b"\x31\xc0", "xorl\t%eax, %eax"), (b"\xc3", "retq")),
         "aarch64": ((0xD2800000, "mov\tx0, #0x0"), (0xD65F03C0, "ret"))}


class Copies:
    """The fixture: four objects of an ELF link probing P at phase.
      1: X, an unsymbolized copy of W1, B;
      2: Y, an unsymbolized copy of P, C;
      3: P, an unsymbolized copy of W2, D;
      4: Z, an unsymbolized copy of V sized so that the copy of P after it
         gets no leading filler (so no filler run marks where it starts), E.
    Each object ends with its package descriptor.  live_post False leaves out
    P's own trailing filler; extra maps a live function to filler bytes
    added before it.  pre[n] is the leading filler of object n's copy of P,
    and probe None builds the same program without a probe."""

    def __init__(self, arch, seed, mode, phase, live_post=True, extra=None):
        self.arch, self.seed, self.mode, self.extra = arch, seed, mode, extra or {}
        self.probe = None if phase is None else (P, phase)
        self.p, self.trail, self.pre = Prog(arch, 0x10000), 0, {}
        for n, (head, copy, tail) in enumerate(((X, W1, B), (Y, P, C), (P, W2, D), (Z, V, E))):
            self.p.start_object(64)
            self.func(head, live=True, post=live_post or head != P)
            if n == 3:
                self.func(copy, live=False, upto=phase)
                self.pre[n] = self.func(P, live=False)
            else:
                pre = self.func(copy, live=False)
                if copy == P:
                    self.pre[n] = pre
            self.func(tail, live=True)
            self.p.fill(self.trail)
            self.trail = 0
            self.p.nops_to(placehash.UNIT[arch])
            self.p.sym("bn_F1_1_%s1_9___Package" % "qrst"[n])
            self.p.op(*INSNS[arch][1])

    def func(self, k, live, post=True, upto=None):
        """Place the function keyed k (symbolized when live) and return its
        leading filler; upto ends its body where the next function, given no
        filler, lands on that phase (when not None)."""
        p, unit = self.p, placehash.UNIT[self.arch]
        pre = p.placed(k, self.seed, self.mode, self.extra.get(k, 0), probe=self.probe,
                       post=self.trail)
        if live:
            p.sym(k)
        more, ret = INSNS[self.arch]
        p.op(*more)
        if upto is not None:
            ret_len = len(ret[0]) if isinstance(ret[0], bytes) else 4
            while (-(-(p.pc - p.obj + ret_len) // unit) * unit - upto) % placehash.PLACE_SPAN:
                p.op(*more)
        p.op(*ret)
        self.trail = placehash.fill_after(k, pre, self.probe) if post else 0
        return pre

    def rows(self, fmt="elf", probe="same"):
        probe = self.probe if probe == "same" else probe
        return {r["name"]: r for r in load(self.p, fmt=fmt).expect_seed(self.seed, self.mode,
                                                                          probe)}


SEEDS = ((0, "phase"), (7, "phase"), (11, "shift"))


class CopiesTest(unittest.TestCase):
    def test_every_phase_passes(self):
        for arch in ("x86_64", "aarch64"):
            unit = placehash.UNIT[arch]
            for seed, mode in SEEDS:
                for phase in range(0, 64, unit):
                    with self.subTest(arch=arch, seed=seed, mode=mode, phase=phase):
                        fx = Copies(arch, seed, mode, phase)
                        rows = fx.rows()
                        self.assertEqual([k for k, r in rows.items() if not r["ok"]], [])
                        self.assertEqual(set(rows), {X, B, Y, C, P, D, Z, E})
                        r = rows[P]
                        self.assertEqual((r["phase"], r["status"]), (phase, "ok"))
                        # The run right after P's body: its trailing filler,
                        # then W2's leading filler (none at seed 0).
                        self.assertTrue(r["after_code"])
                        self.assertEqual(r["want_after"], 64 - r["pre"])
                        if seed == 0:
                            self.assertEqual(r["after"], 64 - r["pre"])
                        else:
                            self.assertLess(r["after"] - r["want_after"], 64)
                            self.assertGreaterEqual(r["after"], r["want_after"])
                        # D follows W2's copy: P's trailing filler is not its.
                        self.assertEqual(rows[D]["post_before"], 0)
                        self.assertEqual(rows[B]["post_before"], 0)
                        # C and E follow copies of P.  In phase mode at a
                        # nonzero seed C's own filler can absorb the copy's
                        # trailing filler, so no copy is needed to explain it.
                        self.assertEqual(fx.pre[3], 0)
                        if seed == 0 or mode == "shift":
                            self.assertEqual(rows[C]["post_before"], 64 - fx.pre[1])
                            self.assertEqual(rows[E]["post_before"], 64)
                        else:
                            self.assertIn(rows[C]["post_before"], (0, 64 - fx.pre[1]))

    def test_pieces(self):
        # aarch64 at seed 0, probing P at phase 20.
        fx = Copies("aarch64", 0, "phase", 20)
        lay = load(fx.p)
        funcs = {f.name: f for f in lay.funcs}
        # After X: W1's copy, with no filler before it at seed 0.
        (run_start, run_len, start, end, _), = lay.tails[funcs[B].addr].pieces
        self.assertEqual((run_start, run_len, start), (funcs[X].end, 0, funcs[X].end))
        self.assertEqual(lay.tails[funcs[B].addr].body_end, end)
        # After Y: the copy of P, after its leading filler, at phase 20.
        (run_start, run_len, start, _, phases), = lay.tails[funcs[C].addr].pieces
        self.assertEqual((run_start, run_len, start % 64), (funcs[Y].end, fx.pre[1], 20))
        self.assertFalse(phases >> 20 & 1)
        # After P: its trailing filler starts the run before W2's copy.
        (run_start, run_len, _, _, _), = lay.tails[funcs[D].addr].pieces
        r = {r["name"]: r for r in lay.expect_seed(0, "phase", fx.probe)}[P]
        self.assertEqual((run_start, run_len), (funcs[P].end, 64 - r["pre"]))
        # After Z: V's copy and P's merge into one piece; an item other than
        # the first starts at phase 20.
        (_, run_len, start, _, phases), = lay.tails[funcs[E].addr].pieces
        self.assertEqual((run_len, start), (0, funcs[Z].end))
        self.assertTrue(phases >> 20 & 1)
        # Code directly after a function's body has none.
        self.assertEqual(lay.tails[funcs["bn_F1_1_q1_9___Package"].addr].pieces, [])

    def test_without_a_probe(self):
        for arch in ("x86_64", "aarch64"):
            for seed, mode in SEEDS:
                with self.subTest(arch=arch, seed=seed, mode=mode):
                    rows = Copies(arch, seed, mode, None).rows()
                    self.assertTrue(all(r["ok"] for r in rows.values()), rows)
                    self.assertTrue(all(r["post_before"] == 0 for r in rows.values()))

    def test_missing_trailing_filler_after_the_live_probe_fails(self):
        # At seed 0 the run after P's body is exactly its trailing filler.  (At
        # a nonzero seed it only has bounds: W2's own filler, whose size its
        # missing symbol hides, can make up for a missing one.)
        for arch in ("x86_64", "aarch64"):
            for phase in range(0, 64, 16):
                with self.subTest(arch=arch, phase=phase):
                    rows = Copies(arch, 0, "phase", phase, live_post=False).rows()
                    self.assertEqual(rows[P]["status"], "FAIL")
                    self.assertEqual(rows[P]["after"], 0)

    def test_extra_filler_after_a_copy_fails(self):
        for arch in ("x86_64", "aarch64"):
            unit = placehash.UNIT[arch]
            for victim in (B, C, D, E):
                with self.subTest(arch=arch, victim=victim):
                    rows = Copies(arch, 0, "phase", 32, extra={victim: unit}).rows()
                    self.assertEqual([k for k, r in rows.items() if not r["ok"]], [victim])

    def test_wrong_probe_fails(self):
        fx = Copies("aarch64", 0, "phase", 20)
        for probe in ((P, 24), (C, 20), None):
            with self.subTest(probe=probe):
                rows = fx.rows(probe=probe)
                self.assertFalse(all(r["ok"] for r in rows.values()))


A64 = [key(c) for c in "abcdefgh"]


def a64_seed0(probe, extra=(), gap=None, post=True):
    """aarch64, seed 0: the A64 functions, then a package descriptor.  The
    functions in extra get 4 bytes of filler a correct backend never emits
    at seed 0; gap puts 16 zero bytes, as a linker's alignment padding,
    before that function; post False leaves out the probe's trailing
    filler."""
    p = Prog("aarch64", 0x10000)
    trail = 0
    for k in A64:
        if k == gap:
            p.skip(16)
        pre = p.placed(k, 0, "phase", extra=4 if k in extra else 0, probe=probe, post=trail)
        trail = placehash.fill_after(k, pre, probe) if post else 0
        p.sym(k)
        p.op(0xD2800000, "mov\tx0, #0x0")
        p.op(0xD65F03C0, "ret")
    p.fill(trail)
    p.sym("bn_F1_1_q1_9___Package")
    p.op(0xD65F03C0, "ret")
    return p


def statuses(prog, fmt, probe):
    rows = load(prog, fmt=fmt).expect_seed(0, "phase", probe)
    return {r["name"]: r["status"] for r in rows}, all(r["ok"] for r in rows)


class MachoSeedZeroProbeTest(unittest.TestCase):
    PROBE = (A64[1], 20)

    def test_filler_before_other_functions_fails(self):
        bad = set(A64[3:6])
        for fmt in ("elf", "macho"):
            for probe in (None, self.PROBE):
                with self.subTest(fmt=fmt, probe=probe):
                    st, ok = statuses(a64_seed0(probe, bad), fmt, probe)
                    self.assertFalse(ok)
                    self.assertEqual({k for k, s in st.items() if s == "FAIL"}, bad)
                    st, ok = statuses(a64_seed0(probe), fmt, probe)
                    self.assertTrue(ok)

    def test_linker_gap_without_filler(self):
        gap = A64[5]
        st, ok = statuses(a64_seed0(self.PROBE, gap=gap), "macho", self.PROBE)
        self.assertTrue(ok)
        self.assertEqual(st[gap], "ok-gap")
        self.assertEqual({s for k, s in st.items() if k != gap}, {"ok"})
        # Filler as well as the gap fails; ELF, and Mach-O with no probe
        # (no 64-byte .text alignment), have no such gap at seed 0.
        self.assertFalse(statuses(a64_seed0(self.PROBE, {gap}, gap), "macho", self.PROBE)[1])
        self.assertFalse(statuses(a64_seed0(self.PROBE, gap=gap), "elf", self.PROBE)[1])
        self.assertFalse(statuses(a64_seed0(None, gap=gap), "macho", None)[1])

    def test_row_after_the_probe_needs_its_trailing_filler(self):
        st, ok = statuses(a64_seed0(self.PROBE, post=False), "macho", self.PROBE)
        self.assertFalse(ok)
        self.assertEqual(st[A64[1]], "FAIL")


if __name__ == "__main__":
    unittest.main()
