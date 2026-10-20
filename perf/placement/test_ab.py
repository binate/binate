"""Tests for ab.py's configuration, build plan, abort checks and timed-phase
logic (ab_config, ab_build, ab_timed); the fake-compiler flows are in
test_ab_flow.py.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import os
import tempfile
import unittest

import ab
import ab_build as bld
import ab_config as cfgm
import ab_store as st
import ab_testutil as tu
import ab_timed as tm
import placehash
import runner


def sample(rc=0, out_hash=""):
    return runner.Sample(*([0.0] * 10 + [out_hash, rc, None, None]))


class SeedsTest(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(cfgm.parse_seeds("1-4"), [1, 2, 3, 4])
        self.assertEqual(cfgm.parse_seeds("7,3, 10-11"), [7, 3, 10, 11])
        for bad in ("0-3", "3-1", "1,1", "x", "1-", "100000"):
            with self.assertRaises(cfgm.ConfigError, msg=bad):
                cfgm.parse_seeds(bad)


class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.bnc = tu.fake_bnc(d)
        self.subject = tu.subject_tree(d)
        self.bench = tu.bench_tree(d, {"foo": ("exact", "7", None),
                                       "bar": ("float", "100", "1\n")})
        self.work = os.path.join(d, "w")

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, *extra, workload="bench"):
        argv = ["run", "--work", self.work, "--arm", "A=" + self.bnc, "--seeds", "1-3",
                "--workload", workload, "--subject", self.subject]
        if workload == "bench":
            argv += ["--bench", self.bench]
        return cfgm.Config(ab.parse_args(argv + list(extra)))

    def test_bench_items(self):
        c = self.config("--n", "foo=9", "--arm", "B=" + self.bnc, "--arm-backend", "B=llvm")
        self.assertEqual([i.name for i in c.items], ["bar", "foo"])
        bar, foo = c.items
        self.assertEqual((foo.n, foo.compare, foo.expected), (9, "exact", None))
        self.assertEqual((bar.n, bar.compare, bar.sub), (100, "float", "b00"))
        self.assertTrue(bar.expected.endswith("bar/expected.txt"))
        self.assertTrue(bar.root.endswith("bench/bar/binate"))
        self.assertEqual([a.backend for a in c.arms], ["native", "llvm"])
        self.assertEqual(c.arms[0].sha, c.arms[1].sha)
        self.assertEqual(c.work_flags, [])

    def test_selfcompile_item_and_work_flags(self):
        c = self.config(workload="selfcompile")
        self.assertEqual(c.work_flags, cfgm.DEFAULT_WORK_FLAGS.split())
        (it,) = c.items
        self.assertEqual((it.kind, it.name, it.sub), ("selfcompile", "bnc", ""))
        self.assertTrue(it.pkg.endswith("subject/cmd/bnc"))
        c = self.config("--work-flags", "--backend native -O2", workload="selfcompile")
        self.assertEqual(c.work_flags, ["--backend", "native", "-O2"])

    def test_errors(self):
        bad = [("--arm-flags", "Z=-O3"), ("--arm-backend", "A=gcc"),
               ("--arm-flags", "A=-fnative-place-seed=3"), ("--arm-flags", "A=--backend llvm"),
               ("--aa", "same"), ("--n", "nope=3"), ("--n", "foo=x"), ("--only", "nope"),
               ("--work-flags=-O2", None), ("--reps", "0"), ("--max-load", "-1"),
               ("--arm", "A=" + self.bnc), ("--arm", "bad name=" + self.bnc),
               ("--arm", "C=/nonexistent/bnc")]
        for flag, val in bad:
            with self.subTest(flag=flag, val=val):
                with self.assertRaises(cfgm.ConfigError):
                    self.config(*([flag] if val is None else [flag, val]))
        with self.assertRaises(cfgm.ConfigError):
            self.config("--bench", self.bench, workload="selfcompile")

    def test_record_holds_layout_inputs(self):
        r = self.config("--tmpdir", os.path.join(self.tmp.name, "t")).record()
        root = os.path.join(os.path.realpath(self.tmp.name), "t")
        self.assertEqual(r["timed_env"], runner.base_env(runner.FIXED_PATH,
                                                         os.path.join(root, "home"),
                                                         os.path.join(root, "tmp")))
        self.assertEqual(len(r["stack_limit"]), 2)
        self.assertIn("personality", r)
        self.assertEqual(sorted(r["sources"]), ["bench/bar", "bench/foo", "expected/bar",
                                                "expected/foo", "subject"])
        self.assertIsNone(r["sources"]["expected/foo"])

    def test_source_digest(self):
        d = os.path.join(self.tmp.name, "src")
        for rel, text in (("a/x.bn", "1"), ("a/y.bni", "2"), ("b/z.s", "3"), ("c/n.md", "4"),
                          (".git/q.bn", "5")):
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            with open(os.path.join(d, rel), "w") as fh:
                fh.write(text)
        first = st.source_digest(d)
        for rel, changes in (("c/n.md", False), (".git/q.bn", False), ("a/x.bn", True)):
            with open(os.path.join(d, rel), "a") as fh:
                fh.write("more")
            self.assertEqual(st.source_digest(d) != first, changes, rel)
        os.rename(os.path.join(d, "b", "z.s"), os.path.join(d, "b", "w.s"))
        self.assertNotEqual(st.source_digest(d), first)
        self.assertIsNone(st.source_digest(os.path.join(d, "missing")))

    def test_config_diff_names_sub_keys(self):
        self.assertEqual(st.config_diff({"e": {"A": 1, "B": 2}, "x": 1},
                                        {"e": {"A": 1, "B": 3, "C": 0}, "x": 2}),
                         ["e.B", "e.C", "x"])

    def test_record_is_resume_key(self):
        a = self.config().record()
        b = self.config("--jobs", "1", "--max-load", "3").record()
        self.assertEqual(st.config_diff(a, b), [])
        c = self.config("--mode", "shift").record()
        self.assertEqual(st.config_diff(a, c), ["mode"])
        d = cfgm.Config(ab.parse_args(["run", "--work", self.work, "--arm", "A=" + self.bnc,
                                       "--seeds", "1-5", "--workload", "bench", "--subject",
                                       self.subject, "--bench", self.bench])).record()
        self.assertEqual(st.config_diff(a, d), [])
        self.assertEqual(st.config_diff(d, a), ["seeds"])


class PlanTest(unittest.TestCase):
    def arms(self):
        return [bld.Arm(0, "A", "/c/a"), bld.Arm(1, "B", "/c/b"),
                bld.Arm(2, "L", "/c/l", backend="llvm")]

    def items(self):
        return [bld.Item(0, "bench", "foo", "/b/foo/binate/cmd/foo", "/b/foo/binate", 7),
                bld.Item(1, "bench", "bar", "/b/bar/binate/cmd/bar", "/b/bar/binate", 9)]

    def test_arm_seed(self):
        self.assertEqual(bld.arm_seed(0, 5, "salted"), 5)
        s1 = placehash.salted_seed(5)
        self.assertEqual(bld.arm_seed(1, 5, "salted"), s1)
        self.assertEqual(bld.arm_seed(2, 5, "salted"), placehash.salted_seed(s1))
        self.assertEqual(bld.arm_seed(1, 5, "same"), 5)
        self.assertEqual(bld.arm_seed(3, 5, None), 5)

    def test_builds(self):
        builds = bld.plan_builds("/w", self.arms(), self.items(), [1, 2, 3], "salted")
        kinds = [b.kind for b in builds]
        self.assertEqual(kinds[:8], ["seed0", "noflag"] * 4)
        self.assertEqual(len(builds), 8 + 3 * 3 * 2)
        llvm = [b for b in builds if b.arm.name == "L"]
        # Seed-major: the first seed builds both items; later seeds link to them.
        self.assertEqual([b.link is None for b in llvm], [True, True] + [False] * 4)
        self.assertEqual([b.link.item.name for b in llvm if b.link], ["foo", "bar"] * 2)
        self.assertTrue(all(b.place_seed is None for b in llvm))
        b_arm = [b for b in builds if b.arm.name == "B" and b.kind == "seed"]
        self.assertEqual(b_arm[0].place_seed, placehash.salted_seed(1))
        self.assertEqual(len({len(b.path) for b in builds}), 1)
        self.assertEqual(len({b.path for b in builds}), len(builds))

    def test_seeded_builds_alternate_the_arms(self):
        # Seed by seed, with the arm order reversed on every other seed, so no
        # arm's binaries are all written after another's.
        builds = bld.plan_builds("/w", self.arms(), self.items(), [1, 2, 3], "salted")
        order = [(b.seed, b.item.name, b.arm.name) for b in builds if b.kind == "seed"]
        self.assertEqual(order[:6], [(1, "foo", "A"), (1, "foo", "B"), (1, "foo", "L"),
                                     (1, "bar", "A"), (1, "bar", "B"), (1, "bar", "L")])
        self.assertEqual(order[6:9], [(2, "foo", "L"), (2, "foo", "B"), (2, "foo", "A")])
        self.assertEqual([s for s, _, _ in order], [1] * 6 + [2] * 6 + [3] * 6)

    def test_compile_argv(self):
        a, _, l = self.arms()
        a.flags = ["-fx64-rax-home"]
        it = self.items()[0]
        b = bld.Build(a, it, "seed", 4, 4, "/w/x/bin")
        self.assertEqual(bld.compile_argv(b, "shift", "I", "L", "/w/x/build"),
                         ["/c/a", "--backend", "native", "-O2", "-fx64-rax-home",
                          "-fnative-place-seed=4", "-fnative-place-mode=shift", "-I", "I",
                          "-L", "L", "--build-dir", "/w/x/build", "-o", "/w/x/bin", it.pkg])
        nf = bld.compile_argv(bld.Build(a, it, "noflag", None, None, "/o"), "phase", "I", "L",
                              "/d")
        self.assertFalse(any(x.startswith("-fnative-place") for x in nf))
        z = bld.compile_argv(bld.Build(a, it, "seed0", 0, 0, "/o"), "phase", "I", "L", "/d")
        self.assertIn("-fnative-place-seed=0", z)
        ll = bld.compile_argv(bld.Build(l, it, "seed", 1, None, "/o"), "phase", "I", "L", "/d")
        self.assertEqual(ll[:6], ["/c/l", "--backend", "llvm", "-O2", "--cflag", "-O2"])
        self.assertFalse(any(x.startswith("-fnative-place") for x in ll))


def row(kind, arm, seed, sha, text, backend="native", expect="ok", item="foo", idx=None):
    return {"kind": kind, "arm": arm, "arm_idx": str(idx if idx is not None else ord(arm[0])),
            "backend": backend, "item": item, "seed": str(seed), "place_seed": str(seed),
            "sha256": sha, "text_sha256": text, "expect_seed": expect,
            "path": "store/x/%s/%s/bin" % (arm, seed)}


class AbortTest(unittest.TestCase):
    def good(self):
        return [row("seed0", "A", 0, "z", "tz"), row("noflag", "A", "", "z", "tz"),
                row("seed", "A", 1, "a1", "t1"), row("seed", "A", 2, "a2", "t2"),
                row("seed0", "B", 0, "y", "ty"), row("noflag", "B", "", "y", "ty"),
                row("seed", "B", 1, "b1", "u1"), row("seed", "B", 2, "b2", "u2")]

    def test_good(self):
        self.assertEqual(bld.abort_reasons(self.good(), None), [])

    def test_text_identical_across_seeds(self):
        rows = self.good()
        rows[3]["text_sha256"] = "t1"
        (why,) = bld.abort_reasons(rows, None)
        self.assertIn("identical for seeds 1 and 2", why)

    def test_llvm_text_may_repeat(self):
        rows = [row("seed", "L", s, "l", "tl", backend="llvm", expect="-") for s in (1, 2)]
        self.assertEqual(bld.abort_reasons(rows, None), [])

    def test_identical_llvm_arms_message(self):
        rows = [row("seed", arm, s, "l", "tl", backend="llvm", expect="-", idx=i)
                for i, arm in enumerate(("L1", "L2")) for s in (1,)]
        (why,) = bld.abort_reasons(rows, "salted")
        self.assertIn("LLVM arms are not placed", why)
        (why,) = bld.abort_reasons(rows, None)
        self.assertIn("needs --aa same or --aa salted", why)

    def test_identical_arms(self):
        rows = self.good()
        rows[6]["sha256"] = "a1"
        (why,) = bld.abort_reasons(rows, None)
        self.assertIn("arms A and B built identical binaries", why)
        # Under --aa same, seed 1 (identical) is as expected and seed 2, where
        # the arms still differ, means the compiler is not deterministic.
        (why,) = bld.abort_reasons(rows, "same")
        self.assertIn("foo, seed 2: under --aa same the arms built different binaries", why)
        self.assertIn("arms A and B", bld.abort_reasons(rows, "salted")[0])
        self.assertEqual(bld.aa_same_differences(self.good()), [("foo", "1"), ("foo", "2")])

    def test_aa_same_identical_arms_pass(self):
        rows = self.good()
        for r in rows:
            if r["kind"] == "seed" and r["arm"] == "B":
                twin = [x for x in rows if x["kind"] == "seed" and x["arm"] == "A"
                        and x["seed"] == r["seed"] and x["item"] == r["item"]]
                r["sha256"] = twin[0]["sha256"]
        self.assertEqual(bld.aa_same_differences(rows), [])
        self.assertEqual([w for w in bld.abort_reasons(rows, "same") if "--aa same" in w], [])

    def test_seed0_differs(self):
        rows = self.good()
        rows[0]["sha256"] = "other"
        (why,) = bld.abort_reasons(rows, None)
        self.assertIn("-fnative-place-seed=0 binary differs", why)

    def test_expect_seed(self):
        for verdict in ("fail", "error"):
            rows = self.good()
            rows[2]["expect_seed"] = verdict
            (why,) = bld.abort_reasons(rows, None)
            self.assertIn("layout.py --expect-seed 1", why)

    def test_covariates(self):
        report = {"summary": {"text_bytes": 900, "bytes": {"fill": 32, "pad": 3},
                              "erratum": {"hits": 4, "windows": 2},
                              "dense_windows": {"count": 1}},
                  "loops": [{"innermost": True, "windows": 4, "windows_min": 3, "lines": 3,
                             "lines_min": 2, "jcc": 1},
                            {"innermost": False, "windows": 9, "windows_min": 3, "lines": 9,
                             "lines_min": 2, "jcc": 5}]}
        self.assertEqual(bld.covariates(report),
                         {"text_bytes": 900, "fill_bytes": 32, "pad_bytes": 3, "jcc_hits": 4,
                          "jcc_windows": 2, "dense_windows": 1, "inner_loops": 1,
                          "inner_excess_windows": 1, "inner_excess_lines": 1, "inner_jcc": 1})
        del report["loops"], report["summary"]["erratum"]
        self.assertEqual(sorted(bld.covariates(report)), ["fill_bytes", "pad_bytes",
                                                          "text_bytes"])


class OutputCheckTest(unittest.TestCase):
    def item(self, compare="exact", n=7, default="7", expected=None):
        return bld.Item(0, "bench", "foo", "/p", n=n, compare=compare, default_n=default,
                        expected=expected)

    def test_bench(self):
        it = self.item()
        self.assertTrue(tm.output_ok(it, sample(), b"Result(7) = 42\n", b"Result(7) = 42\n"))
        self.assertFalse(tm.output_ok(it, sample(), b"Result(7) = 41\n", b"Result(7) = 42\n"))
        self.assertFalse(tm.output_ok(it, sample(rc=1), b"x", b"x"))
        self.assertFalse(tm.output_ok(it, sample(), None, b"x"))
        f = self.item("float")
        self.assertTrue(tm.output_ok(f, sample(), b"0.123456781\n", b"0.123456789\n"))
        self.assertFalse(tm.output_ok(f, sample(), b"0.12345\n", b"0.123456789\n"))

    def test_expected_at_default_n(self):
        with tempfile.TemporaryDirectory() as d:
            exp = os.path.join(d, "expected.txt")
            with open(exp, "wb") as fh:
                fh.write(b"0.10000000\n")
            it = self.item("float", expected=exp)
            # Within 1e-8 of the reference, but not of expected.txt.
            self.assertFalse(tm.output_ok(it, sample(), b"0.100000016\n", b"0.100000008\n"))
            self.assertTrue(tm.output_ok(it, sample(), b"0.100000004\n", b"0.100000008\n"))
            off = self.item("float", n=9, expected=exp)
            self.assertIsNone(tm.expected_bytes(off))
            self.assertTrue(tm.output_ok(off, sample(), b"0.100000016\n", b"0.100000008\n"))

    def test_selfcompile(self):
        it = bld.Item(0, "selfcompile", "bnc", "/s/cmd/bnc")
        self.assertTrue(tm.output_ok(it, sample(out_hash="ab"), None, "ab"))
        self.assertFalse(tm.output_ok(it, sample(out_hash="ac"), None, "ab"))
        self.assertFalse(tm.output_ok(it, sample(out_hash=""), None, ""))
        self.assertFalse(tm.output_ok(it, sample(rc=2, out_hash="ab"), None, "ab"))

    def test_run_argv(self):
        b = self.item(n=11)
        self.assertEqual(tm.run_argv(b, "/w/bin", [], None, "/r"), ["/w/bin", "11"])
        s = bld.Item(0, "selfcompile", "bnc", "/s/cmd/bnc")
        self.assertEqual(tm.run_argv(s, "/w/bin", ["--backend", "native"], ("I", "L"), "/r"),
                         ["/w/bin", "--backend", "native", "-I", "I", "-L", "L", "--build-dir",
                          "/r/build", "-o", "/r/o/bnc", "/s/cmd/bnc"])

    def test_prepare_empties_build_dir(self):
        with tempfile.TemporaryDirectory() as d:
            s = bld.Item(0, "selfcompile", "bnc", "/s/cmd/bnc")
            os.makedirs(os.path.join(d, "build"))
            open(os.path.join(d, "build", "junk.o"), "w").close()
            os.makedirs(os.path.join(d, "o"))
            open(os.path.join(d, "o", "bnc"), "w").close()
            tm.prepare(s, d)
            self.assertEqual(os.listdir(os.path.join(d, "build")), [])
            self.assertFalse(os.path.exists(os.path.join(d, "o", "bnc")))


class LoadAndResumeTest(unittest.TestCase):
    def test_wait_load(self):
        loads = iter([5.0, 4.0, 1.5, 9.0])
        slept, logs = [], []
        waited = tm.wait_load(2.0, logs.append, lambda: (next(loads), 0, 0), slept.append, 7)
        self.assertEqual((waited, slept, len(logs)), (14, [7, 7], 2))
        self.assertEqual(tm.wait_load(None, logs.append, lambda: 1 / 0), 0)

    def srow(self, rd, seed, bench, rep, arm):
        return {"round": str(rd), "seed": str(seed), "bench": bench, "rep": str(rep),
                "arm_idx": str(arm), "out_ok": "1"}

    def test_split_rounds(self):
        seeds = [4, 8, 15]
        rows = [self.srow(0, 4, b, r, a) for b in "xy" for r in range(2) for a in range(2)]
        rows += [self.srow(1, 8, "x", 0, 0), self.srow(1, 8, "x", 0, 1)]
        keep, drop, done = tm.split_rounds(rows, seeds, 2, 2, 2)
        self.assertEqual((len(keep), len(drop), done), (8, 2, {0}))
        with self.assertRaises(ValueError):
            tm.split_rounds([self.srow(0, 5, "x", 0, 0)], seeds, 2, 2, 2)
        dup = rows[:7] + [rows[0]]
        self.assertEqual(tm.split_rounds(dup, seeds, 2, 2, 2)[2], set())
        # A complete round with a failed output check is not finished, even
        # when the failure was its last run.
        bad = [dict(r) for r in rows[:8]]
        bad[-1]["out_ok"] = "0"
        keep, drop, done = tm.split_rounds(bad, seeds, 2, 2, 2)
        self.assertEqual((len(keep), len(drop), done), (0, 8, set()))

    def test_max_load_waits_only_between_rounds(self):
        events = []
        loads = iter([0.1, 9.0, 9.0, 0.1, 9.0, 0.1] + [0.1] * 50)

        def spawn(argv, pad, cwd, out, aslr, env=None, hash_path=None):
            events.append("run")
            with open(out, "wb") as fh:
                fh.write(b"ok\n")
            return sample()
        with tempfile.TemporaryDirectory() as d:
            arms = [bld.Arm(0, "A", "/x"), bld.Arm(1, "B", "/x")]
            items = [bld.Item(0, "bench", "foo", "/p", "/r", 7, "exact", "9", None)]
            os.makedirs(os.path.join(d, "run"))
            samples = st.TsvLog(os.path.join(d, "samples.tsv"), st.SAMPLE_COLS)
            t = tm.Timed(d, arms, items, [1, 2, 3], 2, "on", {}, os.path.join(d, "run"), [],
                         ("", ""), samples, lambda m: None, max_load=1.0, spawn=spawn,
                         load=lambda: (next(loads), 0, 0), sleep=lambda s: events.append("wait"))
            t.refs["foo"] = b"ok\n"
            t.run()
        # Each round's four runs stay together; the waits fall between rounds.
        self.assertEqual(" ".join(events), "run run run run wait wait run run run run wait "
                                            "run run run run")


class TsvTest(unittest.TestCase):
    def test_partial_last_row_dropped_and_trimmed(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.tsv")
            log = st.TsvLog(p, ("a", "b"))
            log.append({"a": 1, "b": 2.5})
            with open(p, "a") as fh:
                fh.write("3\t4")
            self.assertEqual(st.read_tsv(p), [{"a": "1", "b": "2.500000"}])
            log = st.TsvLog(p, ("a", "b"))
            log.append({"a": True, "b": None})
            self.assertEqual(st.read_tsv(p)[1], {"a": "1", "b": ""})
            with self.assertRaises(ValueError):
                st.TsvLog(p, ("a", "c"))
            with self.assertRaises(ValueError):
                log.append({"a": "x\ty"})


if __name__ == "__main__":
    unittest.main()
