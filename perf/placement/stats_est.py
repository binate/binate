"""Estimators for stats.py, per workload item.

All of them work on t = a run's user CPU time (or another metric) on a log
scale.  For seed r and arm a, m[r,a] is the mean of ln t over the replicates
of that (seed, arm) cell, and d[r,a] = m[r,a] - m[r,base].

- difference: D = mean over seeds of d[r,a], as a ratio exp(D) and as a
  percentage, with a 95% percentile bootstrap over seeds and a Student-t
  interval (warned about when there are fewer than 20 seeds), the one-sided
  Student-t p-value of the null "the arm is not slower" (p_slower: small
  when it is slower; the selection guard tests it with a multiplicity
  correction over the items), and the fraction of seeds in which the arm is
  faster;
- spread: the placement SD of an arm, the SD over seeds of its cell means
  with the fitted order terms removed (stats_model: position effects and
  within-round drift) and the run noise of a cell mean (sigma_run^2 times
  the mean of 1/replicates) subtracted, where sigma_run^2 is the arm's
  residual variance inside cells after the order terms; its ratio to the
  base's, with a bootstrap interval that keeps the draws where a placement
  variance estimate is <= 0 (see ratio_ci); the worst decile (90th
  percentile of m[r,a]) relative to the arm's mean and to the base's worst
  decile;
- the variance split of each arm and of each difference into run noise,
  placement noise and (for a difference) the order terms' share;
- position and drift: the order model's position effects, each with its
  standard error and flagged when |t| >= POS_T, and its drift per run inside
  a round, all fitted jointly, so a position effect does not read as drift
  or the reverse; and the slope of each round's mean over the rounds;
- flagged samples (a major page fault, more than STEAL_FRAC of the run's wall
  time stolen, or wall > WALL_FACTOR * (user + sys) + WALL_SLACK): the
  difference is reported with and without them.  The steal counter is the
  whole host's averaged over its CPUs (the run's own CPU is not known), so it
  can flag a run whose own CPU lost nothing or miss one whose CPU lost more.

A run whose user time is 0 cannot enter a log-scale estimate and is left out
of the user-time ones (zero_user counts them).  This happens to runs a few
clock ticks long: Linux splits a process's CPU time into user and system time
in proportion to the ticks that sampled it in each, so such a run's whole time
can land in sys.  Its user + sys stays exact, which is what the user+sys
cross-check uses.

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import math
from collections import defaultdict

import stats_core as sc
import stats_model as sm

WALL_FACTOR, WALL_SLACK, STEAL_FRAC = 1.25, 0.02, 0.02
FEW_SEEDS = 20
POS_T = 3.0


def flag_reasons(s):
    """Why sample s is suspect: 'majflt', 'steal', 'wall'; [] if it is not."""
    out = []
    if s.majflt > 0:
        out.append("majflt")
    if s.steal is not None and s.wall > 0 and s.steal / s.wall > STEAL_FRAC:
        out.append("steal")
    if s.wall > WALL_FACTOR * (s.user + s.sys) + WALL_SLACK:
        out.append("wall")
    return out


# Differences recomputed on other metrics as cross-checks of the user-time
# one; cycles and retired instructions (macOS /usr/bin/time -l) only when
# every cell has them.
CROSS_CHECKS = ("user+sys", "cycles", "insns")


def _place_var(tab, ix):
    m = [tab[i][0] for i in ix]
    dof = sum(tab[i][2] for i in ix)
    run = sum(tab[i][1] for i in ix) / dof if dof > 0 else None
    tot = sc.var(m)
    place = tot - run * sc.mean([tab[i][3] for i in ix]) if run is not None else tot
    return place, run, tot


def difference(d, res):
    """Summary of per-seed differences d (log scale)."""
    n = len(d)
    if n == 0:
        return {"n": 0}
    D = sc.mean(d)
    lo, hi = res.ci(n, lambda ix: sc.mean([d[i] for i in ix]))
    tlo, thi = sc.t_interval(d)
    return {"n": n, "mean": D, "ratio": math.exp(D), "pct": sc.pct(D),
            "boot": [sc.pct(lo), sc.pct(hi)], "p_slower": sc.t_p_above(d),
            "t": [sc.pct(tlo), sc.pct(thi)] if n >= 2 else None,
            "faster": sum(1 for x in d if x < 0) / n, "few": n < FEW_SEEDS,
            "sd": sc.sd(d)}


def _sd_ratio(x, y):
    """The ratio of the SDs behind placement variances x (arm) and y (base):
    infinite when only the base's is <= 0, None when both are."""
    if y > 0:
        return math.sqrt(max(x, 0.0)) / math.sqrt(y)
    return float("inf") if x > 0 else None


def ratio_ci(tab_a, tab_b, res, level=0.95):
    """The bootstrap interval of the spread ratio and its draw counts.  A
    draw where only the base's placement variance is <= 0 has an infinite
    ratio; one where both are has no ratio, and is taken as 0 for the lower
    bound and as infinite for the upper one, so such draws widen the
    interval on both sides instead of being dropped from one."""
    n = len(tab_a)
    lows, highs, inf_n, undef_n = [], [], 0, 0
    for ix in res.draws(n):
        r = _sd_ratio(_place_var(tab_a, ix)[0], _place_var(tab_b, ix)[0])
        if r is None:
            undef_n += 1
            lows.append(0.0)
            highs.append(float("inf"))
            continue
        inf_n += r == float("inf")
        lows.append(r)
        highs.append(r)
    a = (1.0 - level) / 2.0
    return ([sc.quantile(lows, a), sc.quantile(highs, 1.0 - a)],
            {"draws": len(lows), "base_zero": inf_n, "both_zero": undef_n})


def spread(tab_a, tab_b, res, is_base=False):
    """Placement spread of an arm against the base, from their model tables
    (stats_model.OrderModel.table: per seed the cell mean with the fitted
    order terms removed).  For the base itself the ratio is 1 (None when
    its placement variance is <= 0) and has no interval."""
    n = len(tab_a)
    every = list(range(n))
    pa, run_a, tot_a = _place_var(tab_a, every)
    pb, _, _ = _place_var(tab_b, every)
    ci, draws = ratio_ci(tab_a, tab_b, res) if n >= 2 and not is_base else (None, None)
    m_a, m_b = [t[0] for t in tab_a], [t[0] for t in tab_b]
    q_a, q_b = sc.quantile(m_a, 0.9), sc.quantile(m_b, 0.9)
    return {"place_var": pa, "place_sd_pct": 100.0 * math.sqrt(max(pa, 0.0)),
            "run_sd_pct": 100.0 * math.sqrt(run_a) if run_a is not None else None,
            "total_sd_pct": 100.0 * math.sqrt(tot_a), "run_removed": run_a is not None,
            "ratio": (1.0 if pa > 0 else None) if is_base else _sd_ratio(pa, pb),
            "ratio_ci": ci, "ratio_draws": draws,
            "worst_decile_pct": sc.pct(q_a - sc.mean(m_a)),
            "worst_decile_vs_base_pct": sc.pct(q_a - q_b)}


def diff_split(tab_a, tab_b, d_raw, d_adj):
    """The variance of the per-seed difference split, as SDs in percent:
    the order terms' share (the difference the fitted position and drift
    terms make to d), and the rest into run noise and placement noise."""
    every = list(range(len(d_raw)))
    _, run_a, _ = _place_var(tab_a, every)
    _, run_b, _ = _place_var(tab_b, every)
    out = {"total_sd_pct": 100.0 * sc.sd(d_raw),
           "order_sd_pct": 100.0 * sc.sd([x - y for x, y in zip(d_raw, d_adj)]),
           "run_sd_pct": None, "place_sd_pct": None}
    if run_a is not None and run_b is not None:
        run = (run_a * sc.mean([t[3] for t in tab_a]) + run_b * sc.mean([t[3] for t in tab_b]))
        out["run_sd_pct"] = 100.0 * math.sqrt(run)
        out["place_sd_pct"] = 100.0 * math.sqrt(max(sc.var(d_adj) - run, 0.0))
    return out


def position(model, samples):
    """Per position: n, the fitted effect (% relative to the mean over
    positions), its standard error (%), t, and whether |t| >= POS_T; the
    effects are None when the model could not estimate them."""
    count = defaultdict(int)
    for s in samples:
        count[s.pos] += 1
    out = []
    for p in sorted(count):
        if model.pos_eff is None or p >= model.k:
            out.append({"pos": p, "n": count[p], "mean_pct": None, "se_pct": None, "t": None,
                        "biased": False})
            continue
        e, sev = model.pos_eff[p], model.pos_se[p]
        t = e / sev if sev > 0 else float("nan")
        out.append({"pos": p, "n": count[p], "mean_pct": 100.0 * e, "se_pct": 100.0 * sev,
                    "t": t, "biased": abs(t) >= POS_T})
    return out


def drift(model, samples):
    """The within-round drift (% per run, from the order model, None when
    it is not fitted) and the slope of each round's mean ln t over the
    rounds (% per round), with standard errors."""
    per_round = defaultdict(list)
    for s in samples:
        if s.user > 0:
            per_round[s.round].append(math.log(s.user))
    rx = sorted(per_round)
    a_slope, a_se = sc.ols(rx, [sc.mean(per_round[r]) for r in rx])

    def p(v):
        return None if v is None else 100.0 * v
    return {"within_pct_per_run": p(model.beta), "within_se": p(model.beta_se),
            "across_pct_per_round": p(a_slope), "across_se": p(a_se)}


def _raw_d(cells, a, base, seeds):
    return [x - y for x, y in zip(cells.means(a, seeds), cells.means(base, seeds))]


def analyze_item(item, arms, base, res):
    """Every per-item statistic, keyed by arm (see the module doc)."""
    samples = item.samples
    present = [a for a in arms if any(s.arm == a for s in samples)]
    out = {"name": item.name, "workload": item.workload, "n": item.n, "arms": {},
           "samples": len(samples), "zero_user": sum(1 for s in samples if s.user <= 0)}
    if base not in present:
        out["error"] = "no samples of the base arm"
        return out
    cells = sm.Cells(samples)
    model = sm.OrderModel(cells, len({s.arm_idx for s in samples}), present)
    flagged = [s for s in samples if flag_reasons(s)]
    clean = sm.Cells(samples, keep=lambda s: not flag_reasons(s))
    for a in present:
        seeds = cells.seeds([a, base])
        tab_a, tab_b = model.table(a, seeds), model.table(base, seeds)
        d = _raw_d(cells, a, base, seeds)
        r = {"seeds": seeds, "d": d,
             "spread": spread(tab_a, tab_b, res, a == base) if seeds else None}
        if a != base:
            r["diff"] = difference(d, res)
            r["split"] = diff_split(tab_a, tab_b, d, [x[0] - y[0] for x, y in zip(tab_a, tab_b)]
                                    ) if d else None
            for m in CROSS_CHECKS:
                mc = sm.Cells(samples, m)
                ss = mc.seeds([a, base])
                if m == "user+sys" or (ss and ss == seeds):
                    r["diff_" + m] = difference(_raw_d(mc, a, base, ss), res)
            r["diff_unflagged"] = difference(_raw_d(clean, a, base, clean.seeds([a, base])), res)
        out["arms"][a] = r
    reasons = defaultdict(int)
    for s in flagged:
        for why in flag_reasons(s):
            reasons[why] += 1
    out["flagged"] = {"count": len(flagged), "reasons": dict(reasons)}
    kept = [s for s in samples if s.user > 0]
    out["position"] = {"strata": model.strata, "rows": position(model, kept)}
    out["drift"] = drift(model, samples)
    return out


def geomean(items, arm, base, res):
    """The geometric-mean difference over items, per seed the mean over
    items of d, bootstrapped over seeds (the seeds every item ran)."""
    per = [dict(zip(it["arms"][arm]["seeds"], it["arms"][arm]["d"])) for it in items
           if arm in it["arms"]]
    if len(per) < len(items) or not per:
        return None
    seeds = sorted(set.intersection(*[set(p) for p in per]))
    g = [sc.mean([p[r] for p in per]) for r in seeds]
    out = difference(g, res)
    out["seeds"], out["g"] = seeds, g
    return out


def plan_n(sd, halfwidth_pct, level=0.95):
    """Seeds needed for a t interval of the mean difference whose half-width
    on the log scale is ln(1 + halfwidth_pct / 100), for a per-seed SD sd."""
    h = math.log1p(halfwidth_pct / 100.0)
    if h <= 0:
        raise ValueError("half-width must be positive")
    if sd <= 0:
        return 2
    z = 1.959963984540054
    n = max(2, int(math.ceil((z * sd / h) ** 2)))
    while sc.t_ppf(0.5 + level / 2.0, n - 1) * sd / math.sqrt(n) > h:
        n += 1
    return n
