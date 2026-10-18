"""Reading placement A/B experiments (ab.py --work directories) for stats.py.

load(dirs) merges one or more experiment directories (say the benchmarks run
and the self-compile run of one comparison) into workload items keyed by name
(the benchmark's name, or 'selfcompile'), each holding its samples.  Arms are
matched by name across directories and the first arm (the base) must be the
same everywhere; a seed is the same placement seed in every directory, so a
statistic over several items is bootstrapped over seeds jointly.  Text sizes
come from builds.tsv (the seeded builds), and the static covariates of
--static-report runs from the cov.json files it lists.

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import json
import os
from collections import OrderedDict, defaultdict

import ab_store as st

INT_COLS = ("round", "seed", "rep", "pad", "arm_idx", "pos", "maxrss", "minflt", "majflt",
            "nvcsw", "nivcsw")
FLOAT_COLS = ("user", "sys", "wall", "steal", "load1", "cycles", "insns")


class S:
    """One timed run, typed; optional counters are None when not recorded."""
    __slots__ = st.SAMPLE_COLS + ("item",)

    def __init__(self, row):
        for c in st.SAMPLE_COLS:
            v = row.get(c, "")
            if c in INT_COLS:
                v = int(v)
            elif c in FLOAT_COLS:
                v = float(v) if v != "" else None
            elif c == "out_ok":
                v = v == "1"
            setattr(self, c, v)
        self.item = self.bench if self.workload == "bench" else "selfcompile"


class Item:
    __slots__ = ("name", "workload", "n", "samples", "dir")

    def __init__(self, name, workload, n, d):
        self.name, self.workload, self.n, self.dir, self.samples = name, workload, n, d, []


class Data:
    """items: OrderedDict name -> Item; arms: names, base first; backend:
    name -> native/llvm; text: (item, arm) -> text bytes of the build
    without placement switches, or the mean over seeded builds when there is
    none (an LLVM arm, whose builds do not vary); cov: (item, arm, seed) ->
    covariate dict; meta: per directory."""

    def __init__(self):
        self.items, self.arms, self.backend = OrderedDict(), [], {}
        self.text, self.cov, self.meta, self.bad, self.dirs = {}, {}, [], 0, []

    @property
    def base(self):
        return self.arms[0]


def _load_builds(d, data, selfcompile):
    # The seeded builds' text includes their random filler, so comparing it
    # would let filler noise decide the text-size criterion: use the build
    # without placement switches where there is one.
    sizes, plain = defaultdict(list), {}
    for r in st.read_tsv(os.path.join(d, "builds.tsv"), st.BUILD_COLS):
        item = "selfcompile" if selfcompile else r["item"]
        if r["kind"] == "noflag":
            plain[(item, r["arm"])] = int(r["text_size"])
        if r["kind"] != "seed":
            continue
        sizes[(item, r["arm"])].append(int(r["text_size"]))
        if r["cov"]:
            with open(os.path.join(d, r["cov"])) as fh:
                data.cov[(item, r["arm"], int(r["seed"]))] = json.load(fh)
    for k, v in sizes.items():
        data.text[k] = plain.get(k, sum(v) / len(v))


def load(dirs):
    """Data for the experiment directories; ValueError on inconsistency."""
    data = Data()
    for d in dirs:
        meta = st.read_json(os.path.join(d, "meta.json"))
        data.meta.append(meta)
        data.dirs.append(d)
        arms = [a["name"] for a in meta["config"]["arms"]]
        if data.arms and arms[0] != data.arms[0]:
            raise ValueError("%s: base arm %s, but %s has %s" % (d, arms[0], data.dirs[0],
                                                                 data.arms[0]))
        for a in meta["config"]["arms"]:
            if a["name"] not in data.backend:
                data.arms.append(a["name"])
                data.backend[a["name"]] = a["backend"]
            elif data.backend[a["name"]] != a["backend"]:
                raise ValueError("arm %s has backend %s in one directory, %s in another"
                                 % (a["name"], data.backend[a["name"]], a["backend"]))
        rows = st.read_tsv(os.path.join(d, "samples.tsv"), st.SAMPLE_COLS)
        for row in rows:
            s = S(row)
            if s.item not in data.items:
                data.items[s.item] = Item(s.item, s.workload, s.n, d)
            elif data.items[s.item].dir != d:
                raise ValueError("workload item %s appears in %s and %s"
                                 % (s.item, data.items[s.item].dir, d))
            if not s.out_ok:
                data.bad += 1
                continue
            data.items[s.item].samples.append(s)
        _load_builds(d, data, meta["config"]["workload"] == "selfcompile")
    return data
