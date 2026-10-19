"""Tests for ab.py --probe SYM --probe-phases P,...: the arms it makes, the
configuration errors, the probe switches in every build, the layout.py
check, and end to end with fake compilers (ab_testutil), including a probe
that matches nothing.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import contextlib
import io
import os
import tempfile
import unittest
from unittest import mock

import ab
import ab_build as bld
import ab_config as cfgm
import ab_testutil as tu

SYM = "bn_F1_4_main1_3_foo"


class ProbeConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.bnc = tu.fake_bnc(d)
        self.subject = tu.subject_tree(d)
        self.bench = tu.bench_tree(d)
        self.work = os.path.join(d, "w")

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, *extra, machine="x86_64"):
        argv = ["run", "--work", self.work, "--arm", "A=" + self.bnc, "--seeds", "1-3",
                "--workload", "bench", "--subject", self.subject, "--bench", self.bench]
        with mock.patch("platform.machine", return_value=machine):
            return cfgm.Config(ab.parse_args(argv + list(extra)))

    def test_one_arm_per_phase(self):
        c = self.config("--probe", SYM, "--probe-phases", "32,0,48,16", "--arm-flags",
                        "A=-fx64-rax-home")
        self.assertEqual([a.name for a in c.arms], ["A.p32", "A.p00", "A.p48", "A.p16"])
        self.assertEqual([a.idx for a in c.arms], [0, 1, 2, 3])
        self.assertEqual([a.probe for a in c.arms], [(SYM, p) for p in (32, 0, 48, 16)])
        self.assertTrue(all(a.flags == ["-fx64-rax-home"] and a.native for a in c.arms))
        self.assertEqual(len({a.sha for a in c.arms}), 1)
        rec = c.record()["arms"]
        self.assertEqual([r["probe"] for r in rec], [[SYM, p] for p in (32, 0, 48, 16)])
        # Without a probe the arm records keep their earlier shape, so an
        # experiment started before probes existed still resumes.
        self.assertNotIn("probe", self.config().record()["arms"][0])

    def test_host_unit(self):
        self.assertEqual(len(self.config("--probe", SYM, "--probe-phases", "0,4,8",
                                         machine="aarch64").arms), 3)
        self.assertEqual(len(self.config("--probe", SYM, "--probe-phases", "0,8",
                                         machine="mips").arms), 2)
        with self.assertRaises(cfgm.ConfigError):
            self.config("--probe", SYM, "--probe-phases", "0,8")

    def test_errors(self):
        bad = [("--probe", SYM), ("--probe-phases", "0,16"),
               ("--probe", "", "--probe-phases", "0,16"),
               ("--probe", SYM, "--probe-phases", "16"),
               ("--probe", SYM, "--probe-phases", "0,16,16"),
               ("--probe", SYM, "--probe-phases", "0,64"),
               ("--probe", SYM, "--probe-phases=-16,0"),
               ("--probe", SYM, "--probe-phases", "0,x"),
               ("--probe", SYM, "--probe-phases", "0,16", "--aa", "same"),
               ("--probe", SYM, "--probe-phases", "0,16", "--arm", "B=" + self.bnc),
               ("--probe", SYM, "--probe-phases", "0,16", "--arm-backend", "A=llvm")]
        for extra in bad:
            with self.subTest(extra=extra):
                with self.assertRaises(cfgm.ConfigError):
                    self.config(*extra)


class ProbeBuildTest(unittest.TestCase):
    def test_probe_switches_in_every_build(self):
        a = bld.Arm(0, "A.p16", "/c/a", ["-fx64-rax-home"], probe=(SYM, 16))
        it = bld.Item(0, "bench", "foo", "/b/foo/binate/cmd/foo", "/b/foo/binate", 7)
        probe = ["-fnative-place-probe=" + SYM, "-fnative-place-probe-phase=16"]
        for kind, seed in (("seed", 4), ("seed0", 0), ("noflag", None)):
            with self.subTest(kind=kind):
                argv = bld.compile_argv(bld.Build(a, it, kind, seed, seed, "/o"), "shift", "I",
                                        "L", "/d")
                self.assertEqual(argv[4:7], ["-fx64-rax-home"] + probe)
                self.assertEqual(kind != "noflag", "-fnative-place-mode=shift" in argv)

    def test_check_layout_passes_the_probe(self):
        seen = []

        def call(argv, out, err=None):
            seen.append(argv)
            return 3
        b = bld.Builder("/w", "/s", "phase", None, False, 1, {}, None, None)
        b._call = call
        arm = bld.Arm(0, "A.p48", "/c/a", probe=(SYM, 48))
        it = bld.Item(0, "bench", "foo", "/b/foo", "/b")
        verdict, _ = b.check_layout(bld.Build(arm, it, "seed", 2, 2, "/w/s/bin"))
        self.assertEqual(verdict, "noprobe")
        self.assertEqual(seen[0][-4:], ["--probe", SYM, "--probe-phase", "48"])

    def test_noprobe_aborts(self):
        rows = [{"kind": "seed", "arm": "A.p00", "arm_idx": "0", "backend": "native",
                 "item": "foo", "seed": "1", "place_seed": "1", "sha256": "x",
                 "text_sha256": "t", "expect_seed": "noprobe", "path": "store/a00/s1/bin"}]
        (reason,) = bld.abort_reasons(rows, None)
        self.assertIn("the probe matched nothing", reason)


class ProbeFlowTest(tu.FlowBase):
    def test_probe_experiment(self):
        a = self.bnc("a", tag="A")
        status = self.run_ab([("A", a)], "--only", "foo", "--probe", SYM, "--probe-phases",
                             "0,16,32")
        self.assertEqual(status, 0, self.stderr)
        builds = self.builds()
        self.assertEqual({r["arm"] for r in builds}, {"A.p00", "A.p16", "A.p32"})
        self.assertEqual({r["expect_seed"] for r in builds if r["kind"] == "seed"}, {"ok"})
        builds_of = [c for c in tu.calls(a) if "-o" in c]
        self.assertEqual(len(builds_of), 3 * (2 + 3))
        self.assertTrue(all("-fnative-place-probe=" + SYM in c for c in builds_of))
        self.assertEqual({r["arm"] for r in self.samples()}, {"A.p00", "A.p16", "A.p32"})
        arms = self.meta()["config"]["arms"]
        self.assertEqual([r["probe"] for r in arms], [[SYM, 0], [SYM, 16], [SYM, 32]])

    def test_probe_matching_nothing_stops(self):
        a = self.bnc("a", tag="A", probe_misses=True)
        status = self.run_ab([("A", a)], "--only", "foo", "--probe", "bn_nothing",
                             "--probe-phases", "0,16")
        self.assertEqual(status, 3, self.stderr)
        self.assertIn("the probe matched nothing", self.stderr)
        self.assertEqual(self.samples(), [])
        self.assertEqual(self.meta()["status"], "aborted")

    def test_dry_run_shows_the_probe(self):
        a = self.bnc("a")
        out = io.StringIO()
        argv = ["run", "--work", self.work, "--seeds", "1", "--workload", "bench",
                "--subject", self.subject, "--bench", self.bench, "--arm", "A=" + a,
                "--probe", SYM, "--probe-phases", "0,16", "--dry-run"]
        with contextlib.redirect_stdout(out):
            self.assertEqual(ab.main(argv), 0)
        text = out.getvalue()
        self.assertIn("(probe %s at phase 16)" % SYM, text)
        self.assertIn("-fnative-place-probe-phase=16", text)
        self.assertFalse(os.path.exists(self.work))


if __name__ == "__main__":
    unittest.main()
