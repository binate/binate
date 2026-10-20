"""The selection table, the --plan table and the static-covariate table of
stats.py.

Selection applies the rule fixed for choosing a placement policy before any
measurement:

  1. an arm is eligible when its placement is randomized (native), it ran
     every workload item, no item is slower than the base (see below), and
     its text grew by at most TEXT_BUDGET_PCT over the base's (summed over
     the items' binaries), or by more only with a speedup beyond its CI (the
     geometric mean's interval lies below 0);
  2. among the base and the eligible arms, the one with the lowest geometric
     mean time over the items is chosen;
  3. arms tied with it (the 95% interval of the per-seed difference of the
     two geometric means covers 0) are decided by the smaller placement
     spread (pooled_spread: the placement variance summed over the items,
     relative to the base's), then by the smaller text; when a tied arm has
     no spread (no placement variance shows for the base), the text decides;
  4. if the base is chosen, the current policy is kept.

The rule asks for the 8 benchmarks plus the native self-compile over at least
MIN_SEEDS placements.  When the data falls short the table still ranks the
arms but gives no verdict ("decided" is false), and says why.

"Slower" is decided per arm by Holm's step-down test over the items it ran,
on each item's one-sided Student-t p-value of the null "the arm is not
slower" (p_slower), at family-wise level SLOWER_ALPHA: the lower tail of a
95% interval.  When the per-seed differences are normal, a neutral arm is
then rejected for a slowdown on some item at most 2.5% of the time however
many items there are; rejecting an arm when any item's own 95% interval lies
above 0 would reject a neutral one ~20% of the time over 9 items.  Negatively
skewed differences (a long tail of seeds where the arm is faster) raise the
actual level and positively skewed ones lower it: a skew of -1.2 over 40
seeds rejects ~3-5 times the nominal rate at the smallest threshold,
0.025 / 9.  The t p-value is used rather than one from the bootstrap draws
because the percentile bootstrap's tails are thinner than t's (its spread is
too small by sqrt((n - 1) / n), and its tails are normal rather than t's),
which for normal differences doubles the rejection rate at 0.025 / 9.  An
item whose own 95% t interval lies above 0 (p_slower below 0.025) but that
the test keeps is named in a note.

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import math

import stats_core as sc
import stats_est as se
import stats_model as sm

TEXT_BUDGET_PCT = 1.0
MIN_SEEDS = 40
RULE_BENCHES = 8
SLOWER_ALPHA = 0.025


def text_growth(data, arm, items):
    """Percent growth of arm's text bytes over the base's, summed over the
    items' binaries; None when a size is missing."""
    a = b = 0.0
    for it in items:
        ka, kb = (it, arm), (it, data.base)
        if ka not in data.text or kb not in data.text:
            return None
        a += data.text[ka]
        b += data.text[kb]
    return 100.0 * (a / b - 1.0) if b else None


def pooled_spread(analysis, arm, base):
    """The arm's placement spread against the base's over every item: the
    square root of the ratio of their placement variances summed over the
    items (each item's unclipped estimate).  An item whose placement noise is
    below its run noise has a per-item ratio that is mostly estimation noise
    (often 0 or undefined); summing variances lets each item count by the
    placement noise it actually shows.  None when an item lacks either arm
    or the base's sum is <= 0."""
    va = vb = 0.0
    for it in analysis["items"]:
        sa = it["arms"].get(arm, {}).get("spread")
        sb = it["arms"].get(base, {}).get("spread")
        if not sa or not sb:
            return None
        va += sa["place_var"]
        vb += sb["place_var"]
    if vb <= 0:
        return None
    return math.sqrt(max(va, 0.0) / vb)


def slower_items(analysis, arm):
    """(the items on which arm is slower than the base by the Holm test,
    the items whose own 95% t interval lies above 0 but the test keeps, the
    number of items tested).  An item with one seed has no p-value and is
    not slower."""
    fam = [(it["name"], it["arms"][arm]["diff"]) for it in analysis["items"]
           if arm in it["arms"] and it["arms"][arm]["diff"]["n"]]
    ps = [d["p_slower"] if d["p_slower"] is not None else 1.0 for _, d in fam]
    hit = sc.holm(ps, SLOWER_ALPHA)
    slower = [name for (name, _), h in zip(fam, hit) if h]
    kept = [name for (name, _), h, p in zip(fam, hit, ps) if not h and p < SLOWER_ALPHA]
    return slower, kept, len(fam)


def _tie(g_best, g_arm, res):
    """Whether the 95% interval of the per-seed difference covers 0."""
    common = sorted(set(g_best) & set(g_arm))
    diff = [g_arm[r] - g_best[r] for r in common]
    if len(diff) < 2:
        return True
    lo, hi = res.ci(len(diff), lambda ix: sc.mean([diff[i] for i in ix]))
    return lo <= 0.0 <= hi


def selection(data, analysis, res, budget=TEXT_BUDGET_PCT):
    """The selection table (see the module doc) as a dict."""
    names = [it["name"] for it in analysis["items"]]
    base = data.base
    rows, notes = [], []
    gm = analysis["geomean"]
    seeds = None
    every = sorted({r for g in gm.values() if g for r in g["seeds"]})
    for arm in data.arms:
        row = {"arm": arm, "backend": data.backend[arm], "eligible": True, "why": []}
        if arm == base:
            # The base's per-seed difference from itself is 0.
            row.update(geomean_pct=0.0, ci=[0.0, 0.0], slower=[],
                       spread=pooled_spread(analysis, base, base), text_pct=0.0, budget="ok",
                       g=dict.fromkeys(every, 0.0))
            rows.append(row)
            continue
        g = gm.get(arm)
        row["text_pct"] = text_growth(data, arm, names)
        row["spread"] = pooled_spread(analysis, arm, base)
        row["slower"], kept, tested = slower_items(analysis, arm)
        if kept:
            notes.append("%s: not slower by the Holm test over its %d items, though its own 95%% "
                         "t interval lies above 0, on %s" % (arm, tested, ", ".join(kept)))
        if data.backend[arm] != "native":
            row["why"].append("placement not randomized")
        if g is None:
            row["why"].append("did not run every item")
            row.update(geomean_pct=None, ci=None, budget="?", g={})
        else:
            seeds = len(g["seeds"]) if seeds is None else min(seeds, len(g["seeds"]))
            row.update(geomean_pct=g["pct"], ci=g["boot"], g=dict(zip(g["seeds"], g["g"])))
            if row["slower"]:
                row["why"].append("slower on %s (Holm over %d items)"
                                  % (", ".join(row["slower"]), tested))
            tp = row["text_pct"]
            if tp is None:
                row["budget"] = "?"
                row["why"].append("no text size")
            elif tp <= budget:
                row["budget"] = "ok"
            elif g["boot"][1] < 0:
                row["budget"] = "over, with a speedup beyond its CI"
            else:
                row["budget"] = "over"
                row["why"].append("text +%.2f%% over the %.1f%% budget" % (tp, budget))
        row["eligible"] = not row["why"]
        rows.append(row)
    cands = [r for r in rows if r["eligible"]]
    best = min(cands, key=lambda r: r["geomean_pct"])
    tied = [r for r in cands if r is best or _tie(best["g"], r["g"], res)]
    for r in tied:
        r["tie"] = True

    # The spread decides only when every tied arm has one; otherwise the
    # tie goes on to the text size.
    by_spread = len(tied) > 1 and all(r["spread"] is not None for r in tied)
    if len(tied) > 1 and not by_spread:
        notes.append("the tie between %s is not decided by placement spread, which %s lacks "
                     "(the base shows no placement variance, or an item is missing)"
                     % (", ".join(r["arm"] for r in tied),
                        ", ".join(r["arm"] for r in tied if r["spread"] is None)))

    def key(r):
        sp = r["spread"] if by_spread else 0.0
        tp = r["text_pct"] if r["text_pct"] is not None else float("inf")
        return (sp, tp)
    chosen = min(tied, key=key)
    for r in rows:
        r["selected"] = r is chosen
        r.pop("g", None)
    short = (seeds is None or seeds < MIN_SEEDS)
    if seeds is not None and seeds < MIN_SEEDS:
        notes.append("only %d seeds; the rule asks for at least %d placements"
                     % (seeds, MIN_SEEDS))
    benches = [n for n, it in zip(names, analysis["items"]) if it["workload"] == "bench"]
    if len(benches) < RULE_BENCHES or "selfcompile" not in names:
        short = True
        notes.append("the rule asks for the %d benchmarks and the native self-compile; "
                     "this data has %d benchmark(s)%s" % (RULE_BENCHES, len(benches),
                                                         "" if "selfcompile" in names
                                                         else " and no self-compile"))
    over = [r["arm"] for r in rows if r.get("budget", "").startswith("over, with")]
    if over:
        notes.append("text over the %.1f%% budget is accepted for %s for its speedup; how "
                     "much growth a speedup justifies is a judgment call"
                     % (budget, ", ".join(over)))
    return {"rows": rows, "selected": chosen["arm"], "decided": not short,
            "keep_current": chosen["arm"] == base, "notes": notes, "budget_pct": budget}


def plan(analysis, halfwidth):
    """Seeds needed per item and arm, and for the geometric mean, for a 95%
    interval of +-halfwidth percent, from the observed per-seed SDs."""
    rows = []
    for it in analysis["items"]:
        for arm, r in it["arms"].items():
            d = r.get("diff")
            if d and d["n"] >= 2:
                rows.append({"item": it["name"], "arm": arm, "sd_pct": 100.0 * d["sd"],
                             "seeds": se.plan_n(d["sd"], halfwidth)})
    for arm, g in analysis["geomean"].items():
        if g and g["n"] >= 2:
            rows.append({"item": "geomean", "arm": arm, "sd_pct": 100.0 * g["sd"],
                         "seeds": se.plan_n(g["sd"], halfwidth)})
    return {"halfwidth_pct": halfwidth, "rows": rows,
            "seeds": max((r["seeds"] for r in rows), default=None)}


def covariates(data, analysis):
    """Per item and arm, each static covariate that varies over the seeds
    against the per-seed timing: for the base, the correlation of the
    covariate with m[r, base] (centred); for another arm, of its difference
    from the base's covariate with d[r, arm], and the slope (percent per
    unit)."""
    out = []
    base = data.base
    for it in analysis["items"]:
        name = it["name"]
        for arm, r in it["arms"].items():
            seeds = r["seeds"]
            rows = []
            covs = [data.cov.get((name, arm, s)) for s in seeds]
            bcov = [data.cov.get((name, base, s)) for s in seeds]
            if any(c is None for c in covs) or any(c is None for c in bcov):
                continue
            ys = _base_m(data, name, base, seeds) if arm == base else r["d"]
            for k in sorted(covs[0]):
                if arm == base:
                    xs = [c[k] for c in covs]
                else:
                    xs = [c[k] - b[k] for c, b in zip(covs, bcov)]
                rho = sc.pearson(xs, ys)
                if rho is None:
                    continue
                slope, sev = sc.ols(xs, ys)
                rows.append({"cov": k, "r": rho, "slope_pct": 100.0 * slope,
                             "slope_se_pct": 100.0 * sev, "n": len(xs)})
            if rows:
                out.append({"item": name, "arm": arm, "rows": rows})
    return out


def _base_m(data, name, base, seeds):
    return sm.Cells(data.items[name].samples).means(base, seeds)
