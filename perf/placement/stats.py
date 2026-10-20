#!/usr/bin/env python3
"""Analysis of placement-randomized A/B experiments (ab.py --work directories).

  stats.py DIR [DIR ...] [--boot 10000 --boot-seed N] [--plan HALFWIDTH] [--json]

For each workload item (each benchmark, the self-compile) and each arm
against the base (the first arm), it reports from the user CPU times:

- the mean over seeds of d[r,a] (the per-seed mean over replicates of ln t,
  minus the base's), as a ratio and in percent, with a 95% percentile
  bootstrap over seeds (--boot draws from a fixed --boot-seed) and a t
  interval, warning when there are fewer than 20 seeds, and the one-sided t
  p-value of the null "the arm is not slower" that the selection guard uses
  ("p slower"); the same difference in user+sys time (and, where recorded,
  cycles and instructions) as a cross-check;
- the placement spread: each arm's SD over seeds of its per-seed mean ln t
  with the fitted position and drift terms and the replicates' run noise
  removed, its ratio to the base's with a bootstrap interval, the worst
  decile, and the fraction of seeds in which the arm is faster;
- the variance of each arm and each difference split into run noise,
  placement noise and the position and drift terms' share;
- position and drift diagnostics (fitted jointly), and the samples flagged
  for a major page fault, stolen time or wall time far above user + sys,
  with the difference reported with and without them;
- with several items, the geometric mean over them, bootstrapped jointly
  over seeds; then the selection table (stats_select's rule: lowest geometric
  mean, no item slower by a Holm test over the items, text within the budget,
  ties broken by smaller placement spread, then smaller text);
- for experiments run with --static-report, each layout.py covariate that
  varies over the seeds against the per-seed timing;
- with --plan HALFWIDTH, the seeds needed for a 95% interval of +-HALFWIDTH
  percent.

Several directories are analysed together (the benchmarks and the
self-compile of one comparison); arms are matched by name and the seeds are
the same placement seeds in each.  Samples whose output check failed
(out_ok=0) are excluded and counted.  LLVM arms are reported as "placement
not randomized" and are not selectable.  In --json output a value that is
missing (NaN) is null and an infinite one (an unbounded interval end, a ratio
over a zero estimate) is the string "inf" or "-inf".

Modules: stats_core (numerics), stats_data (reading), stats_model (the
position and drift model), stats_est (per-item estimators), stats_select
(selection, plan and covariate tables).

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import argparse
import json
import math
import sys

import stats_core as sc
import stats_data as sd
import stats_est as se
import stats_select as sel


def analyze(data, boot=10000, boot_seed=1, plan_hw=None):
    """The whole analysis as a dict (what --json prints)."""
    res = sc.Resampler(boot, boot_seed)
    items = [se.analyze_item(it, data.arms, data.base, res) for it in data.items.values()]
    out = {"dirs": data.dirs, "arms": [{"name": a, "backend": data.backend[a]}
                                       for a in data.arms],
           "base": data.base, "bad_outputs": data.bad, "boot": boot, "boot_seed": boot_seed,
           "aslr": sorted({m.get("aslr", "?") for m in data.meta}), "items": items}
    out["geomean"] = {a: se.geomean(items, a, data.base, res)
                      for a in data.arms if a != data.base}
    out["selection"] = sel.selection(data, out, res)
    cov = sel.covariates(data, out)
    if cov:
        out["covariates"] = cov
    if plan_hw is not None:
        out["plan"] = sel.plan(out, plan_hw)
    return out


def _f(v, fmt="%+.2f"):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "-"
    return fmt % v


def _ci(c, fmt="%+.2f"):
    return "[%s, %s]" % (_f(c[0], fmt), _f(c[1], fmt)) if c else "-"


def _flag(backend):
    return "" if backend == "native" else "  (placement not randomized)"


def text_item(it, backends, out):
    w = out.write
    size = " N=%s" % it["n"] if it["workload"] == "bench" else ""
    w("\n== %s (%s%s): %d samples ==\n" % (it["name"], it["workload"], size, it["samples"]))
    if it.get("zero_user"):
        w("  WARNING: %d samples have user time 0 and are left out of the user-time "
          "estimates: runs this short have their user/sys split decided by clock-tick "
          "sampling (use a larger N; user+sys%% stays exact)\n" % it["zero_user"])
    if "error" in it:
        w("  %s\n" % it["error"])
        return
    w("  %-12s %5s %7s %8s %20s %20s %8s %7s %9s\n" % ("arm", "seeds", "ratio", "time%",
                                                       "95% bootstrap", "95% t", "p slower",
                                                       "faster", "user+sys%"))
    for arm, r in it["arms"].items():
        if "diff" not in r:
            continue
        d = r["diff"]
        if not d["n"]:
            w("  %-12s no seed has both arms\n" % arm)
            continue
        us = r.get("diff_user+sys")
        w("  %-12s %5d %7s %8s %20s %20s %8s %6.0f%% %9s%s\n"
          % (arm, d["n"], _f(d["ratio"], "%.4f"), _f(d["pct"]), _ci(d["boot"]), _ci(d["t"]),
             _f(d["p_slower"], "%.4f"), 100 * d["faster"], _f(us["pct"]) if us else "-",
             _flag(backends[arm])))
        for m in ("cycles", "insns"):
            if "diff_" + m in r:
                x = r["diff_" + m]
                w("  %-12s %s: %s %s\n" % ("", m, _f(x["pct"]), _ci(x["boot"])))
        if d["few"]:
            w("  %-12s WARNING: fewer than %d seeds; the intervals are rough\n"
              % ("", se.FEW_SEEDS))
    w("  spread (placement SD of the per-seed mean, order terms and run noise removed):\n")
    w("  %-12s %9s %8s %7s %16s %13s %9s\n" % ("arm", "place_sd%", "run_sd%", "ratio",
                                              "95% CI", "worst-decile%", "vs base%"))
    for arm, r in it["arms"].items():
        s = r["spread"]
        if not s:
            continue
        w("  %-12s %9s %8s %7s %16s %13s %9s%s\n"
          % (arm, _f(s["place_sd_pct"], "%.3f"), _f(s["run_sd_pct"], "%.3f"),
             _f(s["ratio"], "%.3f"), _ci(s["ratio_ci"], "%.2f"),
             _f(s["worst_decile_pct"]), _f(s["worst_decile_vs_base_pct"]),
             "" if s["run_removed"] else "  (one replicate: run noise not removed)"))
        dr = s.get("ratio_draws")
        if dr and (dr["base_zero"] or dr["both_zero"]):
            w("  %-12s   ratio CI: in %d of %d draws the base's placement variance is <= 0 "
              "(%d of them the arm's too); those draws count as unbounded\n"
              % ("", dr["base_zero"] + dr["both_zero"], dr["draws"], dr["both_zero"]))
    for arm, r in it["arms"].items():
        sp = r.get("split")
        if sp:
            w("  difference noise %s: SD of d %s%% = placement %s%% + run %s%% + order %s%% "
              "(each estimated separately; they need not add up in quadrature)\n"
              % (arm, _f(sp["total_sd_pct"], "%.3f"), _f(sp["place_sd_pct"], "%.3f"),
                 _f(sp["run_sd_pct"], "%.3f"), _f(sp["order_sd_pct"], "%.3f")))
    fl = it["flagged"]
    w("  flagged samples: %d%s\n" % (fl["count"], " (%s)" % ", ".join(
        "%s %d" % kv for kv in sorted(fl["reasons"].items())) if fl["count"] else ""))
    for arm, r in it["arms"].items():
        u = r.get("diff_unflagged")
        if u and fl["count"]:
            w("    %s: with them %s %s, without them %s %s\n"
              % (arm, _f(r["diff"]["pct"]), _ci(r["diff"]["boot"]),
                 _f(u.get("pct")), _ci(u.get("boot"))))
    pos = it["position"]
    w("  position (effect %% against the mean position, fitted with the drift; %s): %s\n"
      % (" and ".join(pos["strata"]) + " cells" if pos["strata"] else "not estimable",
         "  ".join("%d: %s (t %s)%s" % (p["pos"], _f(p["mean_pct"], "%+.3f"),
                                        _f(p["t"], "%.1f"), " BIASED" if p["biased"] else "")
                   for p in pos["rows"])))
    dr = it["drift"]
    w("  drift: within a round %s%%/run (se %s); across rounds %s%%/round (se %s)\n"
      % (_f(dr["within_pct_per_run"], "%+.4f"), _f(dr["within_se"], "%.4f"),
         _f(dr["across_pct_per_round"], "%+.4f"), _f(dr["across_se"], "%.4f")))


def text_report(a, out=None):
    out = out or sys.stdout
    w = out.write
    backends = {x["name"]: x["backend"] for x in a["arms"]}
    w("stats: %s\n" % " ".join(a["dirs"]))
    w("arms: %s; base %s; ASLR %s; bootstrap %d draws, seed %d\n"
      % (", ".join("%s (%s)" % (x["name"], x["backend"]) for x in a["arms"]), a["base"],
         "/".join(a["aslr"]), a["boot"], a["boot_seed"]))
    if a["bad_outputs"]:
        w("WARNING: %d samples failed their output check and are excluded\n"
          % a["bad_outputs"])
    for it in a["items"]:
        text_item(it, backends, out)
    if len(a["items"]) > 1:
        w("\n== geometric mean over %d items ==\n" % len(a["items"]))
        for arm, g in a["geomean"].items():
            if g is None:
                w("  %-12s did not run every item\n" % arm)
            else:
                w("  %-12s %5d seeds ratio %s %8s %20s t %20s%s\n"
                  % (arm, g["n"], _f(g["ratio"], "%.4f"), _f(g["pct"]), _ci(g["boot"]),
                     _ci(g["t"]), _flag(backends[arm])))
                if g["few"]:
                    w("  %-12s WARNING: fewer than %d seeds; the intervals are rough\n"
                      % ("", se.FEW_SEEDS))
    s = a["selection"]
    w("\n== selection (budget +%.1f%% text) ==\n" % s["budget_pct"])
    w("  %-12s %8s %20s %7s %8s %-12s %s\n" % ("arm", "geomean%", "95% CI", "spread",
                                              "text%", "budget", "verdict"))
    for r in s["rows"]:
        verdict = ("SELECTED" if r["selected"] else ("tie" if r.get("tie") else
                   ("eligible" if r["eligible"] else "not eligible: " + "; ".join(r["why"]))))
        w("  %-12s %8s %20s %7s %8s %-12s %s\n"
          % (r["arm"], _f(r["geomean_pct"]), _ci(r["ci"]), _f(r["spread"], "%.3f"),
             _f(r["text_pct"]), r["budget"][:12], verdict))
    choice = ("keep the current policy (%s)" % s["selected"] if s["keep_current"]
              else "select %s" % s["selected"])
    if s["decided"]:
        w("  -> %s\n" % choice)
    else:
        w("  -> no verdict: the data does not meet the rule (see the notes); on this data "
          "the rule would %s\n" % choice)
    for n in s["notes"]:
        w("  note: %s\n" % n)
    for c in a.get("covariates", []):
        w("\n== static covariates: %s, %s (vs %s) ==\n"
          % (c["item"], c["arm"], "per-seed mean" if c["arm"] == a["base"] else "per-seed d"))
        for r in c["rows"]:
            w("  %-22s r %+.3f  slope %s%% per unit (se %s), n %d\n"
              % (r["cov"], r["r"], _f(r["slope_pct"], "%+.5f"), _f(r["slope_se_pct"], "%.5f"),
                 r["n"]))
    if "plan" in a:
        p = a["plan"]
        w("\n== plan: seeds for a 95%% interval of +-%.3g%% ==\n" % p["halfwidth_pct"])
        for r in p["rows"]:
            w("  %-16s %-12s SD of d %.3f%% -> %d seeds\n"
              % (r["item"], r["arm"], r["sd_pct"], r["seeds"]))
        w("  -> %s seeds\n" % p["seeds"])


def _clean(v):
    """v with NaN as None and infinities as the strings 'inf' and '-inf' (an
    unbounded interval end, a ratio over a zero estimate), so the JSON is
    standard."""
    if isinstance(v, float):
        if math.isinf(v):
            return "inf" if v > 0 else "-inf"
        return None if math.isnan(v) else v
    if isinstance(v, dict):
        return {k: _clean(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_clean(x) for x in v]
    return v


def main(argv=None):
    ap = argparse.ArgumentParser(prog="stats.py", description=__doc__.split("\n\n")[2])
    ap.add_argument("dirs", nargs="+", metavar="DIR", help="ab.py --work directories")
    ap.add_argument("--boot", type=int, default=10000, help="bootstrap draws")
    ap.add_argument("--boot-seed", type=int, default=1, help="bootstrap RNG seed")
    ap.add_argument("--plan", type=float, metavar="HALFWIDTH",
                    help="seeds needed for a 95%% interval of +-HALFWIDTH percent")
    ap.add_argument("--json", action="store_true", help="print the analysis as JSON")
    args = ap.parse_args(argv)
    if args.boot < 100:
        ap.error("--boot must be at least 100")
    if args.plan is not None and args.plan <= 0:
        ap.error("--plan must be positive")
    try:
        data = sd.load(args.dirs)
    except (OSError, ValueError, KeyError) as e:
        print("stats.py: %s" % e, file=sys.stderr)
        return 2
    if not any(it.samples for it in data.items.values()):
        print("stats.py: no usable samples", file=sys.stderr)
        return 2
    a = analyze(data, args.boot, args.boot_seed, args.plan)
    if args.json:
        json.dump(_clean(a), sys.stdout, indent=1)
        sys.stdout.write("\n")
    else:
        text_report(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
