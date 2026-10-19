"""Tests for the probe in layout_seed.py and layout.py (--expect-seed with
--probe SYM --probe-phase P) on the x86-64 fixture program from
layout_testutil.py and small aarch64 programs: the probed function's phase,
the filler around it (followed by a Binate function or by synthesized code),
a probe that matches nothing, a wrong or missing probe, the byte split, and
the command line.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import io
import unittest
import unittest.mock

import layout
import layout_seed
import layout_testutil as tu
import placehash
from layout_disasm import FILL
from layout_testutil import Prog
from test_layout import load


def rows_of(lay, seed, mode="phase", probe=None):
    return {r["name"]: r for r in lay.expect_seed(seed, mode, probe)}


class ProbeRowsTest(unittest.TestCase):
    def test_probe_followed_by_a_binate_function(self):
        for seed, mode in ((0, "phase"), (7, "phase"), (11, "shift")):
            for phase in range(0, 64, 16):
                with self.subTest(seed=seed, mode=mode, phase=phase):
                    probe = (tu.F2, phase)
                    rows = rows_of(load(tu.x86_program(seed, mode, probe=probe)), seed, mode,
                                   probe)
                    self.assertTrue(all(r["ok"] for r in rows.values()), rows)
                    r = rows[tu.F2]
                    self.assertTrue(r["probe"])
                    self.assertEqual((r["phase"], r["want_phase"], r["dphase"]), (phase, phase, 0))
                    # The row after it expected the probe's trailing filler.
                    nxt = rows[tu.F3]
                    self.assertEqual(r["after"], nxt["fill"])
                    self.assertEqual(r["want_after"], nxt["want_fill"])
                    self.assertGreaterEqual(nxt["want_fill"], 64 - r["pre"])
                    self.assertEqual(sum(x["probe"] for x in rows.values()), 1)

    def test_probe_with_c_export_alias(self):
        probe = (tu.F3, 48)
        rows = rows_of(load(tu.x86_program(0, probe=probe)), 0, "phase", probe)
        r = rows[tu.F3]
        self.assertEqual((r["entry_name"], r["phase"], r["status"]), ("cexp", 48, "ok"))
        # f3 is the last Binate function of its object: its trailing filler
        # comes before the package descriptor, which no row checks.
        self.assertEqual((r["after"], r["want_after"]), (64 - r["pre"], 64 - r["pre"]))
        self.assertTrue(all(x["ok"] for x in rows.values()))
        self.assertTrue(all(x["want_fill"] == 0 for k, x in rows.items() if k != tu.F3))

    def test_layout_after_the_probe_does_not_move(self):
        # Every address from the probe's trailing filler on is the same for
        # each phase (the fixture models the backend with placehash).
        for seed, mode in ((0, "phase"), (7, "phase"), (11, "shift")):
            addrs = set()
            for phase in range(0, 64, 16):
                lay = load(tu.x86_program(seed, mode, probe=(tu.F1, phase)))
                addrs.add(tuple(f.addr for f in lay.funcs if f.name != tu.F1))
            self.assertEqual(len(addrs), 1, (seed, mode))

    def test_probe_at_object_start_over_merged_linker_fill(self):
        probe = (tu.G1, 16)
        lay = load(tu.x86_program(7, gap="int3", probe=probe))
        rows = rows_of(lay, 7, "phase", probe)
        g1 = rows[tu.G1]
        # The object's first function: its filler is the prediction at object
        # offset 0, which the linker's INT3 gap fill lengthened.
        self.assertEqual((g1["status"], g1["phase"], g1["pre"]), ("ok>=", 16, 16))
        self.assertEqual(rows[tu.G2]["status"], "ok")
        self.assertGreaterEqual(rows[tu.G2]["want_fill"], 64 - 16)
        self.assertTrue(all(r["ok"] for r in rows.values()))

    def test_probe_before_synthesized_code_is_filler(self):
        # g2 is followed by its package descriptor: once a passing check has
        # settled it, its trailing filler counts as filler, not linker gap.
        probe = (tu.G2, 32)
        prog = tu.x86_program(7, probe=probe)
        unsettled = load(prog).byte_counts()[FILL]
        lay = load(prog)
        rows = rows_of(lay, 7, "phase", probe)
        self.assertTrue(all(r["ok"] for r in rows.values()))
        g2 = rows[tu.G2]
        post = 64 - g2["pre"]
        self.assertEqual(g2["after"], post)
        self.assertEqual(lay.byte_counts()[FILL], unsettled + post)
        want = sum(r["fill"] for r in rows.values()) + post
        self.assertEqual(lay.byte_counts()[FILL], want)

    def test_missing_trailing_filler_fails(self):
        for key, failing in ((tu.F2, tu.F3), (tu.F3, tu.F3)):
            with self.subTest(key=key):
                probe = (key, 32)
                prog = tu.x86_program(7, probe=probe, post=False)
                rows = rows_of(load(prog), 7, "phase", probe)
                self.assertEqual(rows[failing]["status"], "FAIL")

    def test_wrong_probe_fails(self):
        prog = tu.x86_program(7, probe=(tu.F2, 32))
        for probe in ((tu.F2, 48), (tu.F1, 32), None):
            with self.subTest(probe=probe):
                rows = rows_of(load(prog), 7, "phase", probe)
                self.assertFalse(all(r["ok"] for r in rows.values()))

    def test_probe_matching_nothing(self):
        probe = ("bn_F1_4_main1_7_nothing", 16)
        rows = load(tu.x86_program(7)).expect_seed(7, "phase", probe)
        self.assertIsNone(layout_seed.probe_row(rows))
        self.assertTrue(all(r["ok"] for r in rows))

    def test_bad_probe_phase_for_the_unit(self):
        with self.assertRaises(ValueError):
            load(tu.x86_program(7)).expect_seed(7, "phase", (tu.F2, 8))


A64_NAMES = ["bn_F1_4_main1_1_a", "bn_F1_4_main1_1_b", "bn_F1_4_main1_1_c"]


def a64_probed(seed, mode, probe, post=True):
    """aarch64: the A64_NAMES functions, then a package descriptor; post False
    leaves out the probed function's trailing filler."""
    p = Prog("aarch64", 0x10000)
    trail = 0
    for key in A64_NAMES:
        pre = p.placed(key, seed, mode, probe=probe, post=trail)
        trail = placehash.fill_after(key, pre, probe) if post else 0
        p.sym(key)
        p.op(0xD2800000, "mov\tx0, #0x0")
        p.op(0xD65F03C0, "ret")
    p.fill(trail)
    p.sym("bn_F1_4_main1_9___Package")
    p.op(0xD65F03C0, "ret")
    return p


class ProbeArmTest(unittest.TestCase):
    def test_every_phase(self):
        for seed, mode in ((0, "phase"), (5, "phase"), (5, "shift")):
            for i in (1, 2):
                after = set()
                for phase in range(0, 64, 4):
                    probe = (A64_NAMES[i], phase)
                    lay = load(a64_probed(seed, mode, probe))
                    rows = rows_of(lay, seed, mode, probe)
                    self.assertTrue(all(r["ok"] for r in rows.values()), (seed, mode, i, phase))
                    self.assertEqual(rows[A64_NAMES[i]]["phase"], phase)
                    after.add(tuple(f.addr for f in lay.funcs[i + 1:]))
                self.assertEqual(len(after), 1)

    def test_missing_trailing_filler_fails(self):
        for i in (1, 2):
            probe = (A64_NAMES[i], 20)
            rows = rows_of(load(a64_probed(0, "phase", probe, post=False)), 0, "phase", probe)
            self.assertFalse(all(r["ok"] for r in rows.values()))

    def test_macho_checks_the_probe_phase(self):
        b = A64_NAMES[1]
        p = a64_probed(0, "phase", (b, 20))
        self.assertEqual(rows_of(load(p, "macho"), 0, "phase", (b, 20))[b]["status"], "ok")
        self.assertEqual(rows_of(load(p, "macho"), 0, "phase", (b, 24))[b]["status"], "FAIL")


class ProbeCliTest(unittest.TestCase):
    def run_main(self, argv, prog):
        with unittest.mock.patch("layout.analyze", lambda *a, **k: load(prog)), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as out, \
                unittest.mock.patch("sys.stderr", io.StringIO()) as err:
            code = layout.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_exit_codes(self):
        prog = tu.x86_program(7, probe=(tu.F2, 32))
        code, out, _ = self.run_main(["b", "--expect-seed", "7", "--probe", tu.F2,
                                      "--probe-phase", "32"], prog)
        self.assertEqual(code, 0)
        self.assertIn("probe %s: entry" % tu.F2, out)
        self.assertEqual(self.run_main(["b", "--expect-seed", "7", "--probe", tu.F2,
                                        "--probe-phase", "48"], prog)[0], 1)
        code, out, err = self.run_main(["b", "--expect-seed", "7", "--probe", "bn_nothing",
                                        "--probe-phase", "32"], tu.x86_program(7))
        self.assertEqual(code, 3)
        self.assertIn("no function that receives placement filler has this symbol", err)
        self.assertIn("probe bn_nothing: FAILED", out)
        self.assertEqual(self.run_main(["b", "--expect-seed", "7", "--probe", tu.F2,
                                        "--probe-phase", "8"], prog)[0], 2)

    def test_argument_errors(self):
        for argv in (["b", "--expect-seed", "7", "--probe", tu.F2],
                     ["b", "--expect-seed", "7", "--probe-phase", "16"],
                     ["b", "--probe", tu.F2, "--probe-phase", "16"],
                     ["b", "--expect-seed", "7", "--probe", "", "--probe-phase", "16"],
                     ["b", "--expect-seed", "7", "--probe", tu.F2, "--probe-phase", "64"],
                     ["b", "--expect-seed", "7", "--probe", tu.F2, "--probe-phase", "-16"]):
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit) as cm, \
                        unittest.mock.patch("sys.stderr", io.StringIO()):
                    layout.main(argv)
                self.assertEqual(cm.exception.code, 2)

    def test_tsv_and_json_carry_the_probe(self):
        prog = tu.x86_program(0, probe=(tu.F2, 16))
        argv = ["b", "--expect-seed", "0", "--probe", tu.F2, "--probe-phase", "16"]
        _, out, _ = self.run_main(argv + ["--tsv"], prog)
        self.assertIn('probe\t{"sym": "%s", "phase": 16}' % tu.F2, out)
        _, out, _ = self.run_main(argv + ["--json"], prog)
        self.assertIn('"probe": true', out)


if __name__ == "__main__":
    unittest.main()
