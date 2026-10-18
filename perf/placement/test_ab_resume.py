"""End-to-end tests of ab.py run --resume with fake compilers
(ab_testutil.FlowBase): continuing an interrupted experiment, extending its
seeds, rebuilding a missing binary, and refusing a resume whose
configuration, sources, timed environment, stack limit or personality
differ, or whose finished-looking round holds a failed output check.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import os
import unittest
from unittest import mock

import ab_config
import ab_store as st
import ab_testutil as tu
import ab_timed as tm
import runner


class ResumeTest(tu.FlowBase):
    def test_interrupt_then_resume(self):
        a, b = self.bnc("a", tag="A"), self.bnc("b", tag="B")
        real, count = tm.Timed._timed, {"n": 0}

        def flaky(self_, *args):
            count["n"] += 1
            if count["n"] == 7:
                raise KeyboardInterrupt
            return real(self_, *args)
        with mock.patch.object(tm.Timed, "_timed", flaky):
            self.assertEqual(self.run_ab([("A", a), ("B", b)], "--only", "foo"), 130)
        self.assertEqual(self.meta()["status"], "interrupted")
        self.assertEqual(len(self.samples()), 6)
        builds_before = len(tu.calls(a)) + len(tu.calls(b))
        self.assertEqual(self.run_ab([("A", a), ("B", b)], "--only", "foo", "--resume"), 0,
                         self.stderr)
        self.assertEqual(len(tu.calls(a)) + len(tu.calls(b)), builds_before)
        rows = self.samples()
        self.assertEqual(len(rows), 3 * 1 * 2 * 2)
        self.assertEqual(sorted({r["round"] for r in rows}), ["0", "1", "2"])
        dropped = st.read_tsv(os.path.join(self.work, "samples.dropped.tsv"))
        self.assertEqual([r["round"] for r in dropped], ["1", "1"])
        self.assertEqual(len(self.meta()["resumed"]), 1)

    def test_resume_rebuilds_a_missing_binary_once(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1-2"), 0)
        n = len(tu.calls(a))
        os.remove(os.path.join(self.work, "store", "a00", "s00002", "b00", "bin"))
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1-2"), 0,
                         self.stderr)
        self.assertEqual(len(tu.calls(a)), n + 1)
        paths = [r["path"] for r in self.builds()]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(len(paths), 2 + 2)

    def test_resume_extends_seeds_only(self):
        a, b = self.bnc("a", tag="A"), self.bnc("b", tag="B")
        self.assertEqual(self.run_ab([("A", a), ("B", b)], "--only", "foo", seeds="1-2"), 0)
        n = len(tu.calls(a))
        self.assertEqual(self.run_ab([("A", a), ("B", b)], "--only", "foo", "--resume",
                                     seeds="1-3"), 0, self.stderr)
        self.assertEqual(len(tu.calls(a)), n + 1)
        self.assertEqual(len(self.samples()), 3 * 2 * 2)

    def test_resume_refuses_other_config_and_fresh_refuses_nonempty(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 0)
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 2)
        self.assertIn("not empty", self.stderr)
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", "--mode", "shift",
                                     seeds="1"), 2)
        self.assertIn("differs in: mode", self.stderr)
        os.remove(os.path.join(self.work, "meta.json"))
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1"), 2)


class ResumeChecksTest(tu.FlowBase):
    def test_failed_check_in_the_last_run_of_a_round_is_run_again(self):
        # Two arms, one replicate: round 0 runs A, then B, whose seed-1
        # binary prints a wrong result.  A resume must run (and check) that
        # binary again, not take round 0 as finished.
        arms = [("A", self.bnc("a", tag="A")), ("B", self.bnc("b", tag="B", bad_seed=1))]
        self.assertEqual(self.run_ab(arms, "--only", "foo", "--reps", "1"), 3, self.stderr)
        rows = self.samples()
        self.assertEqual([(r["round"], r["arm"], r["out_ok"]) for r in rows],
                         [("0", "A", "1"), ("0", "B", "0")])
        self.assertEqual(self.run_ab(arms, "--only", "foo", "--reps", "1", "--resume"), 3,
                         self.stderr)
        self.assertEqual(self.meta()["status"], "aborted")
        self.assertIn("wrong output", self.meta()["why"])
        dropped = st.read_tsv(os.path.join(self.work, "samples.dropped.tsv"))
        self.assertEqual([(r["arm"], r["out_ok"]) for r in dropped], [("A", "1"), ("B", "0")])
        self.assertEqual([(r["arm"], r["out_ok"]) for r in self.samples()],
                         [("A", "1"), ("B", "0")])

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(text)

    def test_changed_sources_refuse_a_resume(self):
        a = self.bnc("a")
        src = os.path.join(self.bench, "foo", "binate", "cmd", "foo", "main.bn")
        lib = os.path.join(self.subject, "pkg", "lib", "lib.bn")
        self.write(src, "package main\n")
        self.write(lib, "package lib\n")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 0, self.stderr)
        # Files bnc does not read change nothing.
        self.write(os.path.join(self.subject, "notes.md"), "x\n")
        self.write(os.path.join(self.subject, "perf", "tool.py"), "x\n")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1"), 0,
                         self.stderr)
        exp = os.path.join(self.bench, "foo", "expected.txt")
        for path, text, key in ((src, "package main // changed\n", "sources.bench/foo"),
                                (lib, "package lib // changed\n", "sources.subject"),
                                (os.path.join(self.subject, "pkg", "new", "x.bni"), "",
                                 "sources.subject"),
                                (exp, "Result(7) = 42 \n", "sources.expected/foo")):
            with self.subTest(key=key):
                old = None
                if os.path.exists(path):
                    with open(path) as fh:
                        old = fh.read()
                self.write(path, text)
                self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume",
                                             seeds="1-2"), 2)
                self.assertIn("differs in: %s" % key, self.stderr)
                if old is None:
                    os.remove(path)
                else:
                    self.write(path, old)
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1-2"), 0,
                         self.stderr)

    def test_changed_layout_inputs_refuse_a_resume(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 0, self.stderr)
        # The shell's PATH does not reach the timed runs, so it may differ.
        with mock.patch.dict(os.environ, {"PATH": "/a/longer/path:" + os.environ["PATH"]}):
            self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1"),
                             0, self.stderr)
        other = os.path.join(self.d, "other-tmpfs")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1",
                                     tmpdir=other), 2)
        self.assertIn("differs in: timed_env.HOME, timed_env.TMPDIR", self.stderr)
        real = ab_config.resource.getrlimit
        with mock.patch.object(ab_config.resource, "getrlimit",
                               lambda which: (1 << 30, real(which)[1])):
            self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1"),
                             2)
        self.assertIn("differs in: stack_limit", self.stderr)
        with mock.patch.object(runner, "persona_bits", lambda persona="auto": 0x0200000):
            self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1"),
                             2)
        self.assertIn("differs in: personality", self.stderr)

    def test_spellings_of_the_same_directories_resume(self):
        a = self.bnc("a")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", seeds="1"), 0, self.stderr)
        link = os.path.join(self.d, "link")
        os.symlink(self.d, link)
        self.work = os.path.join(link, "work")
        self.subject = os.path.join(link, "subject")
        self.bench = os.path.join(link, "bench")
        self.assertEqual(self.run_ab([("A", a)], "--only", "foo", "--resume", seeds="1-2"), 0,
                         self.stderr)
        self.assertEqual(len(self.meta()["resumed"]), 1)
        self.assertIn("git", self.meta()["resumed"][0])


if __name__ == "__main__":
    unittest.main()
