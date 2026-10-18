"""Synthetic placement A/B experiments for the tests of stats.py.

synth() writes an ab.py-style work directory (meta.json, samples.tsv and,
when text sizes or covariates are given, builds.tsv and cov.json files) whose
user times follow a known model, in the run order ab.py uses
(schedule.round_orders):

  ln t = ln base_time + effect[item][arm] + place[r, arm] + bias[pos]
         + within * (slot in the round) + across * round + run noise

with place[r, arm] ~ N(0, place_sd[arm]) drawn once per seed and arm (an
arm's placement is its own; per item too when place_sd is given per item),
run noise ~ N(0, run_sd) per run, and
optional flagged samples (a major fault and a slowdown) and covariates
correlated with the placement effect.

Python standard library only; nothing runs the tests automatically:
  python3 -m unittest discover perf/placement
"""

import math
import os
import random

import ab_store as st
import schedule


def synth(work, arms=("base", "B"), items=("foo",), seeds=20, reps=2, effect=None,
          place_sd=0.01, run_sd=0.005, within=0.0, across=0.0, bias=None, rng=None,
          backends=None, flag=None, text=None, cov=None, base_time=1.0, fixed_order=False,
          workload="bench"):
    """Write the experiment and return the placement effects, keyed (item,
    seed, arm) with item None unless place_sd is given per item.

    effect: {item: {arm: log effect}} or {arm: log effect} for every item;
    place_sd: one SD, {arm: SD} or {(item, arm): SD}; bias: {pos: log
    bias}; flag: {(item, arm):
    count} samples to make suspect (majflt=1, time x1.3); text: {(item, arm):
    bytes}; cov: function (seed, arm, place) -> covariate dict; fixed_order:
    run the arms in index order every time (a design without balancing)."""
    rng = rng or random.Random(1)
    os.makedirs(work, exist_ok=True)
    k = len(arms)
    seed_list = list(range(1, seeds + 1))
    eff = effect or {}
    if eff and not isinstance(next(iter(eff.values())), dict):
        eff = {it: dict(eff) for it in items}
    sds = place_sd if isinstance(place_sd, dict) else {a: place_sd for a in arms}
    per_item = any(isinstance(key, tuple) for key in sds)
    place = {}
    for it in (items if per_item else (None,)):
        for s in seed_list:
            for a in arms:
                place[(it, s, a)] = rng.gauss(0.0, sds[(it, a)] if per_item else sds[a])
    backends = backends or {}
    st.write_json(os.path.join(work, "meta.json"), {
        "config": {"workload": workload, "seeds": seed_list, "reps": reps,
                   "arms": [{"name": a, "backend": backends.get(a, "native")} for a in arms]},
        "aslr": "off"})
    log = st.TsvLog(os.path.join(work, "samples.tsv"), st.SAMPLE_COLS)
    rows, left = [], dict(flag or {})
    for r, seed in enumerate(seed_list):
        orders = ([list(range(k))] * reps if fixed_order
                  else schedule.round_orders(r, k, reps))
        for item in items:
            for rep, order in enumerate(orders):
                for pos, ai in enumerate(order):
                    a = arms[ai]
                    pl = place[(item if per_item else None, seed, a)]
                    lt = (math.log(base_time) + eff.get(item, {}).get(a, 0.0) + pl
                          + (bias or {}).get(pos, 0.0) + within * (rep * k + pos)
                          + across * r + rng.gauss(0.0, run_sd))
                    majflt = 0
                    if left.get((item, a), 0) > 0 and rng.random() < 0.5:
                        left[(item, a)] -= 1
                        majflt, lt = 1, lt + math.log(1.3)
                    user = math.exp(lt)
                    rows.append({"round": r, "seed": seed, "rep": rep, "pad": 16 * r,
                                 "aslr": "off", "workload": workload,
                                 "bench": item if workload == "bench" else "bnc",
                                 "n": 7, "arm": a, "arm_idx": ai, "pos": pos, "user": user,
                                 "sys": 0.01 * user, "wall": 1.02 * user + 0.001,
                                 "maxrss": 1000, "minflt": 100, "majflt": majflt, "nvcsw": 1,
                                 "nivcsw": 1, "steal": 0.0, "load1": 0.5,
                                 "out_hash": "h", "out_ok": True})
    log.rewrite(rows)
    if text or cov:
        blog = st.TsvLog(os.path.join(work, "builds.tsv"), st.BUILD_COLS)
        for item in items:
            for ai, a in enumerate(arms):
                for seed in seed_list:
                    c = ""
                    if cov:
                        c = os.path.join("cov", "%s-%s-%d.json" % (item, a, seed))
                        os.makedirs(os.path.join(work, "cov"), exist_ok=True)
                        pl = place[(item if per_item else None, seed, a)]
                        st.write_json(os.path.join(work, c), cov(seed, a, pl))
                    blog.append({"kind": "seed", "arm": a, "arm_idx": ai,
                                 "backend": backends.get(a, "native"), "item": item,
                                 "seed": seed, "place_seed": seed, "mode": "phase",
                                 "sha256": "s", "text_sha256": "t",
                                 "text_size": (text or {}).get((item, a), 1000),
                                 "expect_seed": "ok", "build_s": 1.0, "path": "p", "cov": c})
    return place
