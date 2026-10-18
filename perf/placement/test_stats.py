"""Tests for stats.py and its modules on synthetic experiments
(stats_testutil.synth) with a known effect, placement noise, run noise,
linear drift and an injected position bias.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import contextlib
import io
import json
import math
import os
import random
import tempfile
import unittest

import ab_store as st
import stats
import stats_core as sc
import stats_data as sd
import stats_est as se
from stats_testutil import synth


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.n = 0

    def tearDown(self):
        self.tmp.cleanup()

    def dir(self):
        self.n += 1
        return os.path.join(self.tmp.name, "e%d" % self.n)

    def analyze(self, *dirs, boot=1000, plan=None):
        return stats.analyze(sd.load(list(dirs)), boot, 7, plan)


class CoreTest(unittest.TestCase):
    def test_t_quantiles(self):
        for df, want in ((1, 12.7062), (2, 4.3027), (10, 2.2281), (30, 2.0423),
                         (1000, 1.9623)):
            self.assertAlmostEqual(sc.t_ppf(0.975, df), want, places=3)
        self.assertAlmostEqual(sc.t_ppf(0.5, 7), 0.0, places=9)
        self.assertAlmostEqual(sc.t_cdf(-2.2281, 10), 0.025, places=4)

    def test_quantile_and_moments(self):
        self.assertEqual(sc.quantile([1, 2, 3, 4], 0.5), 2.5)
        self.assertEqual(sc.quantile([5], 0.9), 5)
        self.assertAlmostEqual(sc.var([1, 2, 3, 4]), 5 / 3)
        self.assertEqual(sc.var([3]), 0.0)
        slope, sev = sc.ols([0, 1, 2, 3], [1, 3, 5, 7])
        self.assertAlmostEqual(slope, 2.0)
        self.assertAlmostEqual(sev, 0.0)
        self.assertAlmostEqual(sc.pearson([1, 2, 3], [2, 4, 7]), 0.9933992677987828)

    def test_resampler_is_reproducible(self):
        a = sc.Resampler(200, 5).ci(10, lambda ix: sum(ix) / 10.0)
        b = sc.Resampler(200, 5).ci(10, lambda ix: sum(ix) / 10.0)
        c = sc.Resampler(200, 6).ci(10, lambda ix: sum(ix) / 10.0)
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)


class EstimateTest(Tmp):
    def one(self, rng, **kw):
        d = self.dir()
        synth(d, rng=rng, **kw)
        a = self.analyze(d, boot=400)
        return a["items"][0]["arms"]["B"]["diff"]

    def test_unbiased_under_drift_with_bootstrap_coverage(self):
        rng = random.Random(11)
        effect, est, cover = 0.02, [], 0
        sims = 150
        for _ in range(sims):
            d = self.one(rng, effect={"B": effect}, seeds=20, place_sd=0.01, run_sd=0.005,
                         within=0.002, across=0.001)
            est.append(math.log1p(d["pct"] / 100))
            lo, hi = (math.log1p(x / 100) for x in d["boot"])
            cover += lo <= effect <= hi
        se_mean = sc.sd(est) / math.sqrt(sims)
        self.assertLess(abs(sc.mean(est) - effect), 3 * se_mean + 1e-4)
        self.assertGreaterEqual(cover / sims, 0.88)
        self.assertLessEqual(cover / sims, 0.99)

    def test_unbalanced_order_would_be_biased(self):
        # The same drift with arm 0 always first shows the bias the
        # balanced, mirrored order removes.
        rng = random.Random(3)
        d = self.one(rng, effect={"B": 0.0}, seeds=30, place_sd=0.001, run_sd=0.001,
                     within=0.01, fixed_order=True)
        self.assertGreater(d["pct"], 0.5)
        d = self.one(rng, effect={"B": 0.0}, seeds=30, place_sd=0.001, run_sd=0.001,
                     within=0.01)
        self.assertLess(abs(d["pct"]), 0.1)

    def test_aa_covers_zero_and_position_bias_found(self):
        d = self.dir()
        synth(d, seeds=40, place_sd=0.01, run_sd=0.003, bias={0: 0.03}, rng=random.Random(5))
        it = self.analyze(d)["items"][0]
        diff = it["arms"]["B"]["diff"]
        self.assertLessEqual(diff["boot"][0], 0.0)
        self.assertGreaterEqual(diff["boot"][1], 0.0)
        rows = {p["pos"]: p for p in it["position"]["rows"]}
        self.assertTrue(rows[0]["biased"])
        self.assertAlmostEqual(rows[0]["mean_pct"], 1.5, delta=0.3)
        self.assertEqual(it["position"]["strata"], ["within", "between"])

    def test_no_position_bias_not_flagged(self):
        d = self.dir()
        synth(d, seeds=40, rng=random.Random(8))
        rows = self.analyze(d)["items"][0]["position"]["rows"]
        self.assertFalse(any(p["biased"] for p in rows))

    def test_position_with_one_replicate(self):
        d = self.dir()
        synth(d, seeds=60, reps=1, place_sd=0.002, run_sd=0.002, bias={0: 0.03},
              rng=random.Random(2))
        pos = self.analyze(d)["items"][0]["position"]
        self.assertEqual(pos["strata"], ["between"])
        self.assertTrue(pos["rows"][0]["biased"])
        self.assertIsNone(self.analyze(d)["items"][0]["drift"]["within_pct_per_run"])

    def test_spread_ratio_recovers_halving(self):
        covered = 0
        for i in range(5):
            d = self.dir()
            synth(d, seeds=40, place_sd={"base": 0.02, "B": 0.01}, run_sd=0.003,
                  rng=random.Random(100 + i))
            s = self.analyze(d)["items"][0]["arms"]["B"]["spread"]
            lo, hi = s["ratio_ci"]
            covered += lo <= 0.5 <= hi
            self.assertLess(hi, 1.0)
        self.assertGreaterEqual(covered, 4)

    def test_variance_split(self):
        d = self.dir()
        synth(d, seeds=200, reps=4, place_sd=0.01, run_sd=0.004, rng=random.Random(9))
        it = self.analyze(d, boot=200)["items"][0]
        s = it["arms"]["base"]["spread"]
        self.assertAlmostEqual(s["place_sd_pct"], 1.0, delta=0.15)
        self.assertAlmostEqual(s["run_sd_pct"], 0.4, delta=0.04)
        split = it["arms"]["B"]["split"]
        self.assertAlmostEqual(split["place_sd_pct"], math.sqrt(2.0), delta=0.2)
        # A cell mean of 4 replicates has run SD 0.4% / 2, a difference of two
        # such means 0.4% / sqrt(2).
        self.assertAlmostEqual(split["run_sd_pct"], 0.4 / math.sqrt(2.0), delta=0.04)

    def test_drift_diagnostics(self):
        d = self.dir()
        synth(d, seeds=30, place_sd=0.001, run_sd=0.001, within=0.004, across=0.002,
              rng=random.Random(4))
        dr = self.analyze(d)["items"][0]["drift"]
        self.assertAlmostEqual(dr["within_pct_per_run"], 0.4, delta=0.05)
        self.assertAlmostEqual(dr["across_pct_per_round"], 0.2, delta=0.05)

    def test_few_seeds_warned(self):
        d = self.one(random.Random(1), seeds=10)
        self.assertTrue(d["few"])
        self.assertFalse(self.one(random.Random(1), seeds=20)["few"])

    def test_flagged_samples_reported_both_ways(self):
        d = self.dir()
        synth(d, seeds=30, effect={"B": 0.0}, place_sd=0.002, run_sd=0.002,
              flag={("foo", "B"): 12}, rng=random.Random(6))
        it = self.analyze(d)["items"][0]
        n = it["flagged"]["count"]
        self.assertGreater(n, 0)
        self.assertEqual(it["flagged"]["reasons"], {"majflt": n})
        r = it["arms"]["B"]
        self.assertGreater(r["diff"]["pct"], 0.5)
        self.assertLess(abs(r["diff_unflagged"]["pct"]), 0.3)

    def test_flag_reasons(self):
        class S:
            majflt, steal, wall, user, sys = 0, 0.0, 1.0, 0.95, 0.04
        s = S()
        self.assertEqual(se.flag_reasons(s), [])
        s.wall = 2.0
        self.assertEqual(se.flag_reasons(s), ["wall"])
        s.wall, s.steal, s.majflt = 1.0, 0.1, 2
        self.assertEqual(se.flag_reasons(s), ["majflt", "steal"])

    def test_cross_check_user_sys(self):
        d = self.one(random.Random(3), effect={"B": 0.05}, seeds=20)
        self.assertAlmostEqual(d["pct"], 5.13, delta=1.0)


class GeomeanAndPlanTest(Tmp):
    def test_geomean_joint_over_seeds(self):
        d = self.dir()
        synth(d, items=("x", "y"), effect={"x": {"B": 0.01}, "y": {"B": 0.03}}, seeds=30,
              place_sd=0.002, run_sd=0.001, rng=random.Random(12))
        a = self.analyze(d)
        g = a["geomean"]["B"]
        self.assertAlmostEqual(g["pct"], 100 * math.expm1(0.02), delta=0.2)
        self.assertEqual(g["n"], 30)
        per = [it["arms"]["B"]["diff"]["mean"] for it in a["items"]]
        self.assertAlmostEqual(g["mean"], sc.mean(per), places=12)

    def test_plan_arithmetic(self):
        for sdv, h in ((0.02, 1.0), (0.005, 0.25), (0.1, 5.0), (0.001, 2.0)):
            n = se.plan_n(sdv, h)
            want = 2
            while sc.t_ppf(0.975, want - 1) * sdv / math.sqrt(want) > math.log1p(h / 100):
                want += 1
            self.assertEqual(n, want)
        self.assertEqual(se.plan_n(0.0, 1.0), 2)
        # t(0.975, 17) * 0.02 / sqrt(18) = 0.009946 <= ln(1.01) = 0.009950.
        self.assertEqual(se.plan_n(0.02, 1.0), 18)

    def test_plan_in_report(self):
        d = self.dir()
        synth(d, seeds=20, rng=random.Random(2))
        a = self.analyze(d, plan=0.5)
        p = a["plan"]
        (row,) = [r for r in p["rows"] if r["item"] == "foo"]
        self.assertEqual(row["seeds"], se.plan_n(row["sd_pct"] / 100, 0.5))
        self.assertEqual(p["seeds"], max(r["seeds"] for r in p["rows"]))


class SelectionTest(Tmp):
    def run_sel(self, effect, text, place_sd=0.003, backends=None, seeds=40):
        d = self.last_dir = self.dir()
        names = set()
        for v in effect.values():
            names |= set(v) if isinstance(v, dict) else set()
        arms = ("base",) + tuple(sorted(names or effect))
        synth(d, arms=arms, items=("x", "y"), effect=effect, seeds=seeds, place_sd=place_sd,
              run_sd=0.002, text=text, rng=random.Random(21), backends=backends)
        return self.analyze(d)["selection"]

    def text(self, growth):
        out = {}
        for it in ("x", "y"):
            out[(it, "base")] = 10000
            for arm, g in growth.items():
                out[(it, arm)] = int(10000 * (1 + g / 100.0))
        return out

    def test_fastest_eligible_arm_selected(self):
        s = self.run_sel({"B": -0.02, "C": -0.04, "D": -0.06},
                         self.text({"B": 0.5, "C": 3.0, "D": 0.2}),
                         backends={"D": "llvm"})
        rows = {r["arm"]: r for r in s["rows"]}
        self.assertEqual(s["selected"], "C")
        self.assertEqual(rows["C"]["budget"], "over, with a speedup beyond its CI")
        self.assertIn("placement not randomized", rows["D"]["why"])
        self.assertTrue(rows["B"]["eligible"])
        self.assertTrue(any("judgment call" in n for n in s["notes"]))

    def test_over_budget_without_speedup_and_slower_items(self):
        s = self.run_sel({"x": {"B": 0.0, "C": -0.03}, "y": {"B": 0.0, "C": 0.03}},
                         self.text({"B": 2.0, "C": 0.0}))
        rows = {r["arm"]: r for r in s["rows"]}
        self.assertFalse(rows["B"]["eligible"])
        self.assertIn("budget", " ".join(rows["B"]["why"]))
        self.assertEqual(rows["C"]["slower"], ["y"])
        self.assertTrue(s["keep_current"])

    def test_tie_broken_by_spread(self):
        d = self.dir()
        synth(d, arms=("base", "B"), items=("x",), effect={"B": 0.0}, seeds=40,
              place_sd={"base": 0.02, "B": 0.005}, run_sd=0.002,
              text=self.text({"B": 0.0}), rng=random.Random(4))
        s = self.analyze(d)["selection"]
        rows = {r["arm"]: r for r in s["rows"]}
        self.assertTrue(rows["base"].get("tie") and rows["B"].get("tie"))
        self.assertEqual(s["selected"], "B")

    def test_notes_on_short_data(self):
        s = self.run_sel({"B": -0.01}, self.text({"B": 0.0}), seeds=10)
        self.assertTrue(any("only 10 seeds" in n for n in s["notes"]))
        self.assertTrue(any("8 benchmarks" in n for n in s["notes"]))
        self.assertFalse(s["decided"])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            stats.main([self.last_dir, "--boot", "100"])
        self.assertIn("-> no verdict: the data does not meet the rule", out.getvalue())

    def test_text_size_from_unplaced_build(self):
        # Seeded builds carry random filler; the unplaced build's size is the
        # one compared, so filler noise cannot decide the text criterion.
        d = self.dir()
        synth(d, arms=("base", "B"), items=("x",), seeds=4, rng=random.Random(5),
              text={("x", "base"): 10000, ("x", "B"): 9990})
        blog = st.TsvLog(os.path.join(d, "builds.tsv"), st.BUILD_COLS)
        for ai, (arm, size) in enumerate((("base", 9000), ("B", 9050))):
            blog.append({"kind": "noflag", "arm": arm, "arm_idx": ai, "backend": "native",
                         "item": "x", "seed": "", "place_seed": "", "mode": "",
                         "sha256": "n%d" % ai, "text_sha256": "m%d" % ai, "text_size": size,
                         "expect_seed": "-", "build_s": 1.0, "path": "p", "cov": ""})
        data = sd.load([d])
        self.assertEqual((data.text[("x", "base")], data.text[("x", "B")]), (9000, 9050))


class ReportTest(Tmp):
    def test_covariates_relate_to_timing(self):
        d = self.dir()
        synth(d, seeds=30, place_sd=0.01, run_sd=0.001, rng=random.Random(13),
              cov=lambda seed, arm, place: {"jcc_hits": round(1000 * place), "pad": 4})
        cov = self.analyze(d)["covariates"]
        by = {(c["item"], c["arm"]): {r["cov"]: r for r in c["rows"]} for c in cov}
        self.assertGreater(by[("foo", "base")]["jcc_hits"]["r"], 0.9)
        self.assertGreater(by[("foo", "B")]["jcc_hits"]["r"], 0.9)
        self.assertNotIn("pad", by[("foo", "B")])

    def test_main_text_json_and_two_dirs(self):
        d1, d2 = self.dir(), self.dir()
        synth(d1, arms=("base", "B", "L"), items=("x",), seeds=12, rng=random.Random(1),
              backends={"L": "llvm"})
        synth(d2, arms=("base", "B", "L"), items=("bnc",), seeds=12, rng=random.Random(2),
              backends={"L": "llvm"}, workload="selfcompile")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(stats.main([d1, d2, "--boot", "200", "--plan", "1"]), 0)
        text = out.getvalue()
        for want in ("== x (bench", "== selfcompile (selfcompile", "geometric mean over 2",
                     "== selection", "placement not randomized", "== plan", "position",
                     "drift", "spread", "WARNING: fewer than 20 seeds", " ratio "):
            self.assertIn(want, text)
        # The geometric mean has a ratio and its own few-seeds warning.
        geo = text[text.index("geometric mean over 2"):text.index("== selection")]
        self.assertIn("WARNING: fewer than 20 seeds", geo)
        a = stats.analyze(sd.load([d1, d2]), 200, 7)
        self.assertRegex(geo, r"B\s+12 seeds ratio %.4f" % a["geomean"]["B"]["ratio"])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(stats.main([d1, "--json", "--boot", "200"]), 0)
        data = json.loads(out.getvalue())
        self.assertEqual(data["base"], "base")
        self.assertIn("diff_user+sys", data["items"][0]["arms"]["B"])

    def test_bad_outputs_excluded(self):
        d = self.dir()
        synth(d, seeds=5, rng=random.Random(1))
        p = os.path.join(d, "samples.tsv")
        with open(p) as fh:
            lines = fh.read().splitlines()
        cols = lines[0].split("\t")
        f = lines[1].split("\t")
        f[cols.index("out_ok")] = "0"
        lines[1] = "\t".join(f)
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        data = sd.load([d])
        self.assertEqual(data.bad, 1)
        self.assertEqual(len(data.items["foo"].samples), 5 * 2 * 2 - 1)

    def test_zero_user_time_counted_and_warned(self):
        d = self.dir()
        synth(d, seeds=6, rng=random.Random(1))
        p = os.path.join(d, "samples.tsv")
        with open(p) as fh:
            lines = fh.read().splitlines()
        cols = lines[0].split("\t")
        for i in (1, 2, 7):
            f = lines[i].split("\t")
            f[cols.index("user")] = "0.000000"
            lines[i] = "\t".join(f)
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        a = self.analyze(d, boot=200)
        self.assertEqual(a["items"][0]["zero_user"], 3)
        out = io.StringIO()
        stats.text_report(a, out)
        self.assertIn("3 samples have user time 0", out.getvalue())

    def test_mismatched_base_refused(self):
        d1, d2 = self.dir(), self.dir()
        synth(d1, arms=("base", "B"), seeds=3)
        synth(d2, arms=("B", "base"), items=("y",), seeds=3)
        with self.assertRaises(ValueError):
            sd.load([d1, d2])


if __name__ == "__main__":
    unittest.main()
