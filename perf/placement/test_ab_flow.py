"""End-to-end tests of ab.py run with fake compilers (ab_testutil.FlowBase):
the build and timed phases, the timed environment, every abort condition, an
interrupted run, LLVM arms, --aa, --static-report and --dry-run.  --resume
is in test_ab_resume.py.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import contextlib
import io
import os
import unittest
from unittest import mock

import ab_store as st
import ab_testutil as tu
import placehash
import runner
import schedule


class HappyPathTest(tu.FlowBase):
    def test_bench_ab(self):
        a, b = self.bnc("a", tag="A", float="flo"), self.bnc("b", tag="B", float="flo")
        self.assertEqual(self.run_ab([("A", a), ("B", b)]), 0, self.stderr)
        builds = self.builds()
        self.assertEqual(len(builds), 2 * 2 * (2 + 3))
        self.assertEqual({r["expect_seed"] for r in builds if r["kind"] == "seed"}, {"ok"})
        rows = self.samples()
        self.assertEqual(len(rows), 3 * 2 * 2 * 2)
        self.assertEqual({r["out_ok"] for r in rows}, {"1"})
        self.assertEqual({r["aslr"] for r in rows}, {"on"})
        for r in rows:
            self.assertEqual(int(r["pad"]), placehash.stack_pad(int(r["seed"])))
            order = schedule.round_orders(int(r["round"]), 2, 2)[int(r["rep"])]
            self.assertEqual(order[int(r["pos"])], int(r["arm_idx"]))
        self.assertEqual([r["bench"] for r in rows[:8]], ["flo"] * 4 + ["foo"] * 4)
        m = self.meta()
        self.assertEqual(m["status"], "done")
        for key in ("host", "git", "compilers", "config", "preflight", "env", "aslr"):
            self.assertIn(key, m)
        self.assertEqual(m["env"]["TMPDIR"], os.path.join(self.tmpdir, "tmp"))
        self.assertEqual(sorted(m["env"]), ["HOME", "LC_ALL", "PATH", "TMPDIR"])
        self.assertEqual(m["env"], m["config"]["timed_env"])
        self.assertEqual(m["env"]["HOME"], os.path.join(self.tmpdir, "home"))
        self.assertEqual(m["env"]["PATH"], runner.FIXED_PATH)
        self.assertIn("build: 20 of 20 done", self.stderr)
        with open(os.path.join(self.work, "ref", "foo.out")) as fh:
            self.assertEqual(fh.read(), "Result(7) = 42\n")

    def test_drop_caches_between_build_and_timed_phases(self):
        calls = []
        drop = lambda: calls.append(len(self.samples()))  # noqa: E731
        with mock.patch.object(runner, "drop_page_cache", drop):
            self.assertEqual(self.run_ab([("A", self.bnc("a"))], "--only", "foo", seeds="1",
                                         drop="auto"), 0, self.stderr)
        self.assertEqual(calls, [0])  # once, after the builds, before any timed run
        self.assertIn("page cache dropped", self.stderr)
        self.assertEqual(self.meta()["config"]["drop_caches"], "auto")

    def test_drop_caches_failure_warns_on_auto_and_stops_on_on(self):
        def denied():
            raise PermissionError(13, "Permission denied")
        with mock.patch.object(runner, "drop_page_cache", denied):
            self.assertEqual(self.run_ab([("A", self.bnc("a"))], "--only", "foo", seeds="1",
                                         drop="auto"), 0, self.stderr)
            self.assertIn("WARNING: could not drop the page cache", self.stderr)
            self.work = os.path.join(self.d, "work2")
            self.assertEqual(self.run_ab([("A", self.bnc("a"))], "--only", "foo", seeds="1",
                                         drop="on"), 1, self.stderr)

    def test_short_reference_run_stops_unless_allowed(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1",
                                     allow_short=False), 3, self.stderr)
        self.assertIn("--allow-short-runs", self.stderr)
        self.assertEqual(self.samples(), [])

    def test_timed_env_does_not_come_from_the_shell(self):
        a = self.bnc("a")
        long_path = "/a/much/longer/path/entry/that/a/venv/would/add:" + os.environ["PATH"]
        with mock.patch.dict(os.environ, {"PATH": long_path, "HOME": "/elsewhere"}):
            self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 0,
                             self.stderr)
        m = self.meta()
        self.assertEqual(m["env"]["PATH"], runner.FIXED_PATH)
        self.assertEqual(m["env"]["HOME"], os.path.join(self.tmpdir, "home"))
        # The untimed builds keep the shell's PATH (to find clang, llvm-objdump).
        self.assertEqual(m["build_env"]["PATH"], long_path)

    def test_inherited_personality_flags_are_reported(self):
        with mock.patch.object(runner, "persona_bits", lambda persona="auto": 0x0200000):
            self.assertEqual(self.run_ab([("A", self.bnc("a"))], "--only", "foo", seeds="1"), 0,
                             self.stderr)
        self.assertIn("personality(2) flags 0x200000 are set", self.stderr)
        self.assertEqual(self.meta()["config"]["personality"], 0x0200000)

    def test_selfcompile(self):
        a, b = self.bnc("a", tag="A"), self.bnc("b", tag="B")
        self.assertEqual(self.run_ab([("A", a), ("B", b)], workload="selfcompile",
                                     seeds="1-2"), 0, self.stderr)
        rows = self.samples()
        self.assertEqual(len(rows), 2 * 2 * 2)
        self.assertEqual(len({r["out_hash"] for r in rows}), 1)
        self.assertTrue(os.path.isfile(os.path.join(self.work, "store", "a01", "s00002",
                                                    "bin")))
        self.assertEqual({r["bench"] for r in rows}, {"bnc"})

    def test_aa_salted_and_same(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a), ("A2", a)], "--aa", "salted"), 0, self.stderr)
        b_rows = [r for r in self.builds() if r["arm"] == "A2" and r["kind"] == "seed"]
        self.assertEqual({int(r["place_seed"]) for r in b_rows if r["seed"] == "1"},
                         {placehash.salted_seed(1)})
        self.work = os.path.join(self.d, "work2")
        self.assertEqual(self.run_ab([("A", a), ("A2", a)], "--aa", "same"), 0, self.stderr)
        shas = {(r["item"], r["seed"]): set() for r in self.builds()}
        for r in self.builds():
            if r["kind"] == "seed":
                shas[(r["item"], r["seed"])].add(r["sha256"])
        self.assertTrue(all(len(v) == 1 for k, v in shas.items() if k[1] not in ("0", "")))

    def test_llvm_arm(self):
        a, b = self.bnc("a", tag="A"), self.bnc("b", tag="B")
        self.assertEqual(self.run_ab([("A", a), ("L", b)], "--arm-backend", "L=llvm"), 0,
                         self.stderr)
        self.assertIn("placement not randomized", self.stderr)
        # Every build, the hard-linked LLVM seeds too, counts towards the total.
        self.assertIn("build: 16 of 16 done", self.stderr)
        self.assertEqual(len(tu.calls(b)), 2)  # one build per item
        llvm = [r for r in self.builds() if r["arm"] == "L"]
        self.assertEqual(len(llvm), 2 * 3)
        self.assertEqual({r["expect_seed"] for r in llvm}, {"-"})
        paths = [os.path.join(self.work, r["path"]) for r in llvm if r["item"] == "foo"]
        self.assertEqual(len({os.stat(p).st_ino for p in paths}), 1)

    def test_static_report(self):
        a, b = self.bnc("a", tag="A"), self.bnc("b", tag="B")
        self.assertEqual(self.run_ab([("A", a), ("B", b)], "--static-report", "--only", "foo"),
                         0, self.stderr)
        seeded = [r for r in self.builds() if r["kind"] == "seed"]
        self.assertTrue(all(r["cov"] for r in seeded))
        for r in seeded:
            cov = st.read_json(os.path.join(self.work, r["cov"]))
            self.assertEqual(cov["jcc_hits"], int(r["place_seed"]) % 5)
            self.assertTrue(os.path.isfile(os.path.join(self.work, os.path.dirname(r["path"]),
                                                        "layout.json.gz")))

    def test_dry_run_touches_nothing(self):
        a = self.bnc("a")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.run_ab([("A", a)], "--dry-run"), 0)
        self.assertFalse(os.path.exists(self.work))
        self.assertEqual(tu.calls(a), [])
        text = out.getvalue()
        self.assertIn("-fnative-place-seed=3", text)
        self.assertIn("round 2 seed 3 pad %d" % placehash.stack_pad(3), text)


class AbortFlowTest(tu.FlowBase):
    def check_abort(self, status, words):
        self.assertEqual(status, 3, self.stderr)
        m = self.meta()
        self.assertEqual(m["status"], "aborted")
        self.assertIn(words, m["why"])
        with open(os.path.join(self.work, "log.txt")) as fh:
            self.assertIn("ABORT: ", fh.read())

    def test_identical_arms(self):
        a = self.bnc("a")
        self.check_abort(self.run_ab([("A", a), ("B", a)]), "identical binaries")
        self.assertEqual(self.samples(), [])

    def test_seed_has_no_effect(self):
        self.check_abort(self.run_ab([("A", self.bnc("a", ignore_seed=True))]),
                         ".text is identical for seeds")

    def test_seed0_differs(self):
        self.check_abort(self.run_ab([("A", self.bnc("a", seed0_differs=True))]),
                         "-fnative-place-seed=0 binary differs")

    def test_layout_check_fails(self):
        self.check_abort(self.run_ab([("A", self.bnc("a", bad_layout=True))]),
                         "layout.py --expect-seed")

    def test_wrong_output_stops_and_is_logged(self):
        self.check_abort(self.run_ab([("A", self.bnc("a", tag="A")),
                                      ("B", self.bnc("b", tag="B", bad_seed=2))]),
                         "wrong output")
        rows = self.samples()
        self.assertEqual(rows[-1]["out_ok"], "0")
        self.assertEqual((rows[-1]["arm"], rows[-1]["seed"]), ("B", "2"))
        self.assertTrue(all(r["out_ok"] == "1" for r in rows[:-1]))
        kept = sorted(os.listdir(os.path.join(self.work, "failed")))
        self.assertEqual(len(kept), 2)
        with open(os.path.join(self.work, "failed", kept[1])) as fh:
            self.assertIn("= 99", fh.read())

    def test_identical_llvm_arms_with_aa_salted(self):
        a = self.bnc("a")
        self.check_abort(self.run_ab([("L1", a), ("L2", a)], "--arm-backend", "L1=llvm",
                                     "--arm-backend", "L2=llvm", "--aa", "salted",
                                     "--only", "foo"), "LLVM arms are not placed")
        self.assertNotIn("needs --aa same or --aa salted", self.meta()["why"])

    def test_interrupted_timed_run(self):
        # The program dies of SIGINT, as with a Ctrl-C to the process group:
        # the experiment is interrupted (130), not failed or aborted.
        status = self.run_ab([("A", self.bnc("a", tag="A")),
                              ("B", self.bnc("b", tag="B", sigint_seed=2))], "--only", "foo")
        self.assertEqual(status, 130, self.stderr)
        self.assertEqual(self.meta()["status"], "interrupted")
        self.assertTrue(all(r["out_ok"] == "1" for r in self.samples()))
        self.assertEqual({r["seed"] for r in self.samples()}, {"1"})

    def test_interrupted_build(self):
        status = self.run_ab([("A", self.bnc("a", tag="A")),
                              ("B", self.bnc("b", tag="B", sigint_build=2))], "--only", "foo")
        self.assertEqual(status, 130, self.stderr)
        self.assertEqual(self.meta()["status"], "interrupted")

    def test_nondeterministic_selfcompile(self):
        self.check_abort(self.run_ab([("A", self.bnc("a", tag="A", nondet=True))],
                                     workload="selfcompile", seeds="1"), "wrong output")

    def test_reference_against_expected(self):
        with open(os.path.join(self.bench, "foo", "expected.txt"), "w") as fh:
            fh.write("Result(7) = 43\n")
        self.check_abort(self.run_ab([("A", self.bnc("a"))], "--only", "foo"),
                         "does not match")

    def test_build_failure(self):
        self.assertEqual(self.run_ab([("A", self.bnc("a", fail_seed=2))]), 1)
        self.assertEqual(self.meta()["status"], "failed")
        self.assertIn("failed (exit", self.meta()["why"])


if __name__ == "__main__":
    unittest.main()
