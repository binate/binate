"""Tests for the run-order model (stats_model) and the statistics built on it:
the run-noise and placement split under position effects and drift, the
position and drift diagnostics, the spread-ratio interval, and the pooled
placement spread the selection's tie-break uses.  The synthetic experiments
(stats_testutil.synth) inject the effects the mirrored Williams schedule is
meant to meet: a position bias and a linear drift inside each round.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import math
import os
import random
import tempfile
import unittest

import stats
import stats_core as sc
import stats_data as sd
import stats_est as se
import stats_select as sel
from stats_testutil import synth


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.n = 0

    def tearDown(self):
        self.tmp.cleanup()

    def item(self, boot=300, **kw):
        self.n += 1
        d = os.path.join(self.tmp.name, "e%d" % self.n)
        synth(d, **kw)
        a = stats.analyze(sd.load([d]), boot, 7)
        self.last = a
        return a["items"][0]


class RunNoiseTest(Base):
    def test_split_survives_position_bias_and_drift(self):
        # The same truth as a clean run: placement SD 1%, run SD 0.4%.  A
        # position bias or a drift inside the cells must not move into the
        # run noise (and from there out of the placement noise).
        for extra in ({"bias": {0: 0.01}}, {"within": 0.002},
                      {"bias": {1: 0.02}, "within": -0.003}):
            with self.subTest(**{k: str(v) for k, v in extra.items()}):
                it = self.item(boot=200, seeds=200, reps=4, place_sd=0.01, run_sd=0.004,
                               rng=random.Random(9), **extra)
                s = it["arms"]["base"]["spread"]
                self.assertAlmostEqual(s["place_sd_pct"], 1.0, delta=0.15)
                self.assertAlmostEqual(s["run_sd_pct"], 0.4, delta=0.04)
                split = it["arms"]["B"]["split"]
                self.assertAlmostEqual(split["place_sd_pct"], math.sqrt(2.0), delta=0.2)
                self.assertAlmostEqual(split["run_sd_pct"], 0.4 / math.sqrt(2.0), delta=0.04)

    def test_spread_ratio_recovers_halving_under_drift(self):
        covered = 0
        for i in range(5):
            it = self.item(seeds=40, place_sd={"base": 0.01, "B": 0.005}, run_sd=0.003,
                           within=0.003, bias={0: 0.01}, rng=random.Random(200 + i))
            lo, hi = it["arms"]["B"]["spread"]["ratio_ci"]
            covered += lo <= 0.5 <= hi
        self.assertGreaterEqual(covered, 4)

    def test_symmetric_position_effect_is_not_placement(self):
        # k = 3 with mirrored replicates: a bias at the middle position sits
        # in every cell that holds it twice, so it varies the cell means
        # from seed to seed like placement noise would.
        it = self.item(arms=("base", "B", "C"), seeds=60, place_sd=0.005, run_sd=0.003,
                       bias={1: 0.03}, rng=random.Random(3))
        for arm in ("base", "B", "C"):
            self.assertAlmostEqual(it["arms"][arm]["spread"]["place_sd_pct"], 0.5, delta=0.15)


class PositionTest(Base):
    def rows(self, it):
        return {p["pos"]: p for p in it["position"]["rows"]}

    def test_middle_position_found_with_mirrored_replicates(self):
        it = self.item(arms=("base", "B", "C"), seeds=60, place_sd=0.005, run_sd=0.003,
                       bias={1: 0.03}, rng=random.Random(3))
        rows = self.rows(it)
        self.assertEqual(it["position"]["strata"], ["within", "between"])
        # Centred: +3% at position 1 of 3 is +2% there and -1% elsewhere.
        for p, want in ((0, -1.0), (1, 2.0), (2, -1.0)):
            self.assertAlmostEqual(rows[p]["mean_pct"], want, delta=0.25)
        self.assertTrue(rows[1]["biased"])

    def test_end_position_not_mirrored_onto_the_other_end(self):
        it = self.item(arms=("base", "B", "C"), seeds=60, place_sd=0.005, run_sd=0.003,
                       bias={0: 0.03}, rng=random.Random(3))
        rows = self.rows(it)
        for p, want in ((0, 2.0), (1, -1.0), (2, -1.0)):
            self.assertAlmostEqual(rows[p]["mean_pct"], want, delta=0.25)
        self.assertGreater(it["arms"]["base"]["spread"]["place_sd_pct"], 0.3)

    def test_position_bias_not_read_as_drift(self):
        dr = self.item(seeds=40, place_sd=0.005, run_sd=0.003, bias={0: 0.03},
                       rng=random.Random(5))["drift"]
        self.assertLess(abs(dr["within_pct_per_run"]), 3 * dr["within_se"])

    def test_drift_not_read_as_position_bias(self):
        it = self.item(seeds=40, place_sd=0.005, run_sd=0.003, within=0.005,
                       rng=random.Random(5))
        self.assertFalse(any(p["biased"] for p in it["position"]["rows"]))
        self.assertAlmostEqual(it["drift"]["within_pct_per_run"], 0.5, delta=0.05)

    def test_standard_errors_are_calibrated(self):
        # Over repeated experiments, the 95% intervals of the position
        # effects and the drift cover the truth about 95% of the time.
        rng, hits, total = random.Random(17), 0, 0
        truth = {0: 0.25, 1: 0.25, 2: -0.75, 3: 0.25}
        for _ in range(25):
            it = self.item(boot=100, arms=("base", "B", "C", "D"), seeds=24, reps=3,
                           place_sd=0.005, run_sd=0.003, bias={2: -0.01}, within=0.002,
                           rng=rng)
            for p in it["position"]["rows"]:
                hits += abs(p["mean_pct"] - truth[p["pos"]]) <= 1.96 * p["se_pct"]
                total += 1
            dr = it["drift"]
            hits += abs(dr["within_pct_per_run"] - 0.2) <= 1.96 * dr["within_se"]
            total += 1
        self.assertGreaterEqual(hits / total, 0.88)
        self.assertLessEqual(hits / total, 0.99)


def cell_table(rng, n, place_sd, run_sd):
    """A model table for n seeds with two replicates per cell."""
    out = []
    for _ in range(n):
        p = rng.gauss(0.0, place_sd)
        y = [p + rng.gauss(0.0, run_sd) for _ in range(2)]
        m = sc.mean(y)
        out.append((m, sum((v - m) ** 2 for v in y), 1.0, 0.5))
    return out


class RatioTest(unittest.TestCase):
    def test_point_ratio(self):
        self.assertEqual(se._sd_ratio(4.0, 1.0), 2.0)
        self.assertEqual(se._sd_ratio(-1.0, 1.0), 0.0)
        self.assertEqual(se._sd_ratio(1.0, -1.0), float("inf"))
        self.assertIsNone(se._sd_ratio(-1.0, 0.0))

    def test_interval_is_symmetric_in_the_arms(self):
        # Swapping the arms turns every draw's ratio r into 1/r, so the
        # interval must turn into [1/hi, 1/lo]; a draw where the base's
        # variance is <= 0 counts at the top, not nowhere.  With 401 draws
        # both percentiles fall on single draws, so this holds exactly.
        rng = random.Random(4)
        ta, tb = cell_table(rng, 30, 0.001, 0.005), cell_table(rng, 30, 0.001, 0.005)
        res = sc.Resampler(401, 3)
        ab, dab = se.ratio_ci(ta, tb, res)
        ba, dba = se.ratio_ci(tb, ta, res)
        self.assertGreater(dab["base_zero"] + dab["both_zero"], 0)
        for x, y in ((ab[0], ba[1]), (ab[1], ba[0])):
            if x == 0.0 or math.isinf(x):
                self.assertEqual(y, float("inf") if x == 0.0 else 0.0)
            else:
                self.assertAlmostEqual(x * y, 1.0, places=9)

    def test_aa_interval_misses_evenly(self):
        rng, below, above = random.Random(8), 0, 0
        for i in range(150):
            ta, tb = cell_table(rng, 40, 0.002, 0.005), cell_table(rng, 40, 0.002, 0.005)
            lo, hi = se.ratio_ci(ta, tb, sc.Resampler(300, i))[0]
            below += hi < 1.0
            above += lo > 1.0
        self.assertLessEqual(below, 12)
        self.assertLessEqual(above, 12)
        self.assertLessEqual(abs(below - above), 8)


class JsonTest(unittest.TestCase):
    def test_infinities_are_strings(self):
        # An unbounded interval end must stay distinguishable from a missing
        # (NaN) value in the standard JSON stats.py --json prints.
        got = stats._clean({"ci": [0.5, float("inf")], "x": (float("nan"), -float("inf"))})
        self.assertEqual(got, {"ci": [0.5, "inf"], "x": [None, "-inf"]})


class PooledSpreadTest(Base):
    def test_one_quiet_item_does_not_decide_the_tie(self):
        # B has twice the base's placement SD on x; on y neither shows
        # placement noise above the run noise.  The tie goes to the base.
        it_text = {(it, a): 10000 for it in ("x", "y") for a in ("base", "B")}
        sds = {("x", "base"): 0.01, ("x", "B"): 0.02, ("y", "base"): 0.0005,
               ("y", "B"): 0.0005}
        chosen = []
        for i in range(6):
            self.item(items=("x", "y"), seeds=40, place_sd=sds, run_sd=0.005, text=it_text,
                      rng=random.Random(i))
            s = self.last["selection"]
            rows = {r["arm"]: r for r in s["rows"]}
            if rows["base"].get("tie") and rows["B"].get("tie"):
                self.assertGreater(rows["B"]["spread"], 1.2)
                chosen.append(s["selected"])
        self.assertTrue(chosen)
        self.assertEqual(set(chosen), {"base"})

    def test_pooled_spread_sums_variances(self):
        def item(va, vb):
            return {"arms": {"A": {"spread": {"place_var": vb}},
                             "B": {"spread": {"place_var": va}}}}
        an = {"items": [item(4.0, 1.0), item(-0.1, 0.01)]}
        self.assertAlmostEqual(sel.pooled_spread(an, "B", "A"), math.sqrt(3.9 / 1.01))
        self.assertIsNone(sel.pooled_spread({"items": [item(1.0, -0.5)]}, "B", "A"))
        self.assertEqual(sel.pooled_spread({"items": [item(-1.0, 0.5)]}, "B", "A"), 0.0)
        self.assertIsNone(sel.pooled_spread({"items": [{"arms": {"A": {"spread": {
            "place_var": 1.0}}}}]}, "B", "A"))

    def test_tie_without_spread_goes_to_text(self):
        class Data:
            arms, base = ["A", "B"], "A"
            backend = {"A": "native", "B": "native"}
            text = {("x", "A"): 1000, ("x", "B"): 990}

        def arm(var):
            return {"diff": {"n": 3, "boot": [-1.0, 1.0]}, "spread": {"place_var": var}}
        an = {"items": [{"name": "x", "workload": "bench",
                         "arms": {"A": arm(-1e-6), "B": arm(1e-6)}}],
              "geomean": {"B": {"seeds": [1, 2, 3], "g": [0.01, -0.01, 0.0], "pct": 0.0,
                                "boot": [-1.0, 1.0]}}}
        s = sel.selection(Data(), an, sc.Resampler(200, 1))
        rows = {r["arm"]: r for r in s["rows"]}
        self.assertIsNone(rows["A"]["spread"])
        self.assertEqual(s["selected"], "B")
        self.assertTrue(any("not decided by placement spread" in n for n in s["notes"]))


if __name__ == "__main__":
    unittest.main()
