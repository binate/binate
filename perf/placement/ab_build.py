"""Build phase of a placement A/B experiment (ab.py run): untimed, --jobs wide.

Every (arm, workload item, round seed) is built into the fixed-width store
path ab_store.bin_path names.  A native arm builds with

  BNC --backend native -O2 <arm flags> -fnative-place-seed=S
      -fnative-place-mode=M -I ... -L ... --build-dir ... -o .../bin PKG

where S is the round seed (with --aa salted, arm i gets placehash.salted_seed
applied i times, so A/A arms are placed differently) and -I/-L come from
SUBJECT/scripts/binate-paths.sh (with the benchmark's binate/ root prepended in
bench mode).  An LLVM arm (--arm-backend NAME=llvm) builds with --backend llvm
-O2 --cflag -O2 and no placement switches, once per item; every round then
runs that same binary (hard-linked into each seed's path), so its placement is
not randomized.

Each native arm also gets two control builds per item: seed 0 (placement
switches given, placement off) and one without any placement switch.  An arm
of a probe experiment (ab.py --probe) adds -fnative-place-probe=SYM
-fnative-place-probe-phase=P to every one of its builds, the controls
included, so its controls check that seed 0 adds nothing to the probe.  The
experiment is aborted when

- a native arm's .text is byte-identical for two seeds (the switches did
  nothing);
- two arms built identical binaries for a seed, unless --aa same;
- under --aa same, the arms built different binaries for a seed (the
  compiler's output is not deterministic);
- a native arm's seed-0 binary differs from its no-switch binary;
- `layout.py BIN --expect-seed S --mode M` (with --probe SYM --probe-phase P
  for a probe arm) fails on a seeded build: the filler is not where
  placehash predicts, or no function has the probe symbol (layout.py exits
  3), so the probe matched nothing and every phase built the same program.

With --static-report the layout.py run also writes its --json --loops report
(gzipped) and the per-binary covariates stats.py relates to per-seed timing.

Python standard library only.  The tests are in test_ab.py; nothing runs them
automatically:
  python3 -m unittest discover perf/placement
"""

import concurrent.futures
import gzip
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections import defaultdict

import ab_store as st
import binfile
import placehash
import runner

LAYOUT_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "layout.py")
NATIVE, LLVM = "native", "llvm"


class Arm:
    """One compiler configuration under test; idx 0 is the base.  probe is
    None or the (symbol, phase) every build of the arm probes."""
    __slots__ = ("idx", "name", "bnc", "flags", "backend", "sha", "probe")

    def __init__(self, idx, name, bnc, flags=(), backend=NATIVE, sha="", probe=None):
        self.idx, self.name, self.bnc = idx, name, bnc
        self.flags, self.backend, self.sha = list(flags), backend, sha
        self.probe = probe

    @property
    def native(self):
        return self.backend == NATIVE


class Item:
    """One workload item: the self-compile, or one benchmark at size n."""
    __slots__ = ("idx", "kind", "name", "sub", "pkg", "root", "n", "compare",
                 "default_n", "expected")

    def __init__(self, idx, kind, name, pkg, root=None, n=None, compare=None,
                 default_n=None, expected=None):
        self.idx, self.kind, self.name, self.pkg, self.root = idx, kind, name, pkg, root
        self.n, self.compare, self.default_n, self.expected = n, compare, default_n, expected
        self.sub = st.item_sub(kind, idx)


class Build:
    """One build: kind 'seed' (round seed `seed`), 'seed0' or 'noflag'; for an
    LLVM arm every seed after the first is a hard link to `link`'s output."""
    __slots__ = ("arm", "item", "kind", "seed", "place_seed", "path", "link")

    def __init__(self, arm, item, kind, seed, place_seed, path, link=None):
        self.arm, self.item, self.kind, self.seed = arm, item, kind, seed
        self.place_seed, self.path, self.link = place_seed, path, link

    def __repr__(self):
        return "%s %s/%s %s" % (self.kind, self.arm.name, self.item.name,
                                st.seed_label(self.seed))


class BuildError(RuntimeError):
    """A build or its layout check could not be run."""


class Abort(RuntimeError):
    """A check stopped the experiment; args[0] lists the reasons."""


def arm_seed(arm_idx, seed, aa):
    """The placement seed arm arm_idx builds with in the round for seed."""
    s = seed
    if aa == "salted":
        for _ in range(arm_idx):
            s = placehash.salted_seed(s)
    return s


def plan_builds(work, arms, items, seeds, aa):
    """Every build, the native control builds first so a broken seed-0
    identity stops the experiment before the long part.  The seeded builds go
    seed by seed, the arms in turn and in reverse order on every other seed,
    so no arm's binaries are written, and their page-cache pages allocated,
    systematically later than another's: when one arm's binaries were all
    built after the other's, a 14 MB-text bnc ran ~0.7% slower in the later
    arm although both arms used the same compiler."""
    controls, seeded, first = [], [], {}
    for item in items:
        for arm in arms:
            if arm.native:
                for kind, seed in (("seed0", 0), ("noflag", None)):
                    controls.append(Build(arm, item, kind, seed, seed,
                                          st.bin_path(work, arm.idx, seed, item.sub)))
    for i, s in enumerate(seeds):
        for item in items:
            for arm in (arms if i % 2 == 0 else arms[::-1]):
                key = (arm.idx, item.idx)
                ps = arm_seed(arm.idx, s, aa) if arm.native else None
                b = Build(arm, item, "seed", s, ps, st.bin_path(work, arm.idx, s, item.sub),
                          None if arm.native else first.get(key))
                first.setdefault(key, b)
                seeded.append(b)
    return controls + seeded


def compile_argv(b, mode, iface, impl, bdir):
    """The bnc command line for build b."""
    arm = b.arm
    if arm.native:
        argv = [arm.bnc, "--backend", "native", "-O2"] + arm.flags
        if arm.probe is not None:
            argv += ["-fnative-place-probe=%s" % arm.probe[0],
                     "-fnative-place-probe-phase=%d" % arm.probe[1]]
        if b.kind != "noflag":
            argv += ["-fnative-place-seed=%d" % b.place_seed, "-fnative-place-mode=%s" % mode]
    else:
        argv = [arm.bnc, "--backend", "llvm", "-O2", "--cflag", "-O2"] + arm.flags
    return argv + ["-I", iface, "-L", impl, "--build-dir", bdir, "-o", b.path, b.item.pkg]


def search_paths(subject, root=None):
    """(-I, -L) from SUBJECT/scripts/binate-paths.sh --base SUBJECT, with root
    prepended when given."""
    script = os.path.join(subject, "scripts", "binate-paths.sh")
    out = []
    for sel in ("--iface", "--impl"):
        argv = [script, sel, "--base", subject] + (["--prepend", root] if root else [])
        p = subprocess.run(argv, capture_output=True, text=True)
        if p.returncode != 0:
            raise BuildError("%s failed: %s" % (" ".join(argv), p.stderr.strip()))
        out.append(p.stdout.strip())
    return tuple(out)


def covariates(report):
    """Per-binary static covariates from a layout.py --json (--loops) report:
    text, filler and pad bytes, and on x86-64 the JCC-erratum hits and
    windows and the dense windows; with loops, over the innermost loops,
    their count, the windows and lines they touch beyond the minimum their
    size needs, and (x86-64) their erratum hits."""
    s = report["summary"]
    cov = {"text_bytes": s["text_bytes"], "fill_bytes": s["bytes"]["fill"],
           "pad_bytes": s["bytes"]["pad"]}
    if "erratum" in s:
        cov["jcc_hits"] = s["erratum"]["hits"]
        cov["jcc_windows"] = s["erratum"]["windows"]
        cov["dense_windows"] = s["dense_windows"]["count"]
    if "loops" in report:
        inner = [lp for lp in report["loops"] if lp.get("innermost")]
        cov["inner_loops"] = len(inner)
        cov["inner_excess_windows"] = sum(lp["windows"] - lp["windows_min"] for lp in inner)
        cov["inner_excess_lines"] = sum(lp["lines"] - lp["lines_min"] for lp in inner)
        if "erratum" in s:
            cov["inner_jcc"] = sum(lp.get("jcc", 0) for lp in inner)
    return cov


# Why a seeded build's layout.py check stops the experiment, by its verdict.
EXPECT_WHY = {"fail": "found the filler different from placehash's prediction",
              "error": "could not check",
              "noprobe": "found no function with the --probe symbol, so the probe matched "
                         "nothing"}


def _norm(row):
    return {k: st._cell(v) for k, v in row.items()}


def abort_reasons(rows, aa):
    """Why the builds so far (builds.tsv rows, as strings) must stop the
    experiment; [] when they need not.  See the module doc."""
    reasons = []
    groups = defaultdict(list)
    for r in rows:
        groups[(int(r["arm_idx"]), r["arm"], r["item"])].append(r)
    for (_, arm, item), rs in sorted(groups.items()):
        if rs[0]["backend"] != NATIVE:
            continue
        seen = {}
        for r in rs:
            if r["kind"] != "seed":
                continue
            if r["text_sha256"] in seen:
                reasons.append("arm %s, %s: .text is identical for seeds %s and %s, so the "
                               "placement switches had no effect"
                               % (arm, item, seen[r["text_sha256"]], r["seed"]))
            seen.setdefault(r["text_sha256"], r["seed"])
            if r["expect_seed"] in ("fail", "error", "noprobe"):
                reasons.append("arm %s, %s, seed %s: layout.py --expect-seed %s %s (see %s)"
                               % (arm, item, r["seed"], r["place_seed"],
                                  EXPECT_WHY[r["expect_seed"]],
                                  os.path.join(os.path.dirname(r["path"]), "layout.err")))
        ctl = {r["kind"]: r["sha256"] for r in rs if r["kind"] in ("seed0", "noflag")}
        if len(ctl) == 2 and ctl["seed0"] != ctl["noflag"]:
            reasons.append("arm %s, %s: the -fnative-place-seed=0 binary differs from the one "
                           "built without placement switches" % (arm, item))
    if aa == "same":
        for item, seed in aa_same_differences(rows):
            reasons.append("%s, seed %s: under --aa same the arms built different binaries, "
                           "so the compiler's output is not deterministic" % (item, seed))
    else:
        by_seed = defaultdict(dict)
        for r in rows:
            if r["kind"] == "seed":
                arms = by_seed[(r["item"], r["seed"])]
                if r["sha256"] in arms:
                    first = arms[r["sha256"]]
                    reasons.append("%s, seed %s: arms %s and %s built identical binaries (%s)"
                                   % (r["item"], r["seed"], first[0], r["arm"],
                                      _identical_why(aa, first[1], r["backend"])))
                arms.setdefault(r["sha256"], (r["arm"], r["backend"]))
    return reasons


def _identical_why(aa, back_a, back_b):
    if aa == "salted" and NATIVE not in (back_a, back_b):
        return ("LLVM arms are not placed, so --aa salted cannot tell them apart; an A/A "
                "run of LLVM arms needs --aa same")
    if aa == "salted":
        return "--aa salted gave them different placement seeds, which changed nothing"
    return "an A/A run of one configuration needs --aa same or --aa salted"


def aa_same_differences(rows):
    """(item, seed) pairs where --aa same arms built different binaries."""
    by_seed = defaultdict(set)
    for r in rows:
        if r["kind"] == "seed":
            by_seed[(r["item"], r["seed"])].add(r["sha256"])
    return sorted(k for k, v in by_seed.items() if len(v) > 1)


class Builder:
    """Runs the build phase; see the module doc."""

    def __init__(self, work, subject, mode, aa, static_report, jobs, env, log, tsv,
                 old_rows=()):
        self.work, self.subject, self.mode, self.aa = work, subject, mode, aa
        self.static, self.jobs, self.env, self.log, self.tsv = static_report, jobs, env, log, tsv
        self.old = {r["path"]: r for r in old_rows}
        self.paths, self.procs, self.lock = {}, set(), threading.Lock()
        self.stopping = False
        self.text_facts = binfile.text_facts

    def rel(self, path):
        return os.path.relpath(path, self.work)

    def _paths(self, item):
        if item.root not in self.paths:
            self.paths[item.root] = search_paths(self.subject, item.root)
        return self.paths[item.root]

    def _call(self, argv, out_path, err_path=None):
        """Run argv with stdout to out_path (stderr too unless err_path)."""
        with open(out_path, "wb") as out:
            err = open(err_path, "wb") if err_path else subprocess.STDOUT
            try:
                with self.lock:
                    if self.stopping:
                        raise BuildError("stopping")
                    p = subprocess.Popen(argv, cwd=self.work, env=self.env,
                                         stdin=subprocess.DEVNULL, stdout=out, stderr=err)
                    self.procs.add(p)
                try:
                    rc = p.wait()
                finally:
                    with self.lock:
                        self.procs.discard(p)
                # A build killed by SIGINT or SIGTERM was interrupted (a
                # Ctrl-C reaches the whole process group), not broken.
                if rc in runner.INTERRUPT_CODES and not self.stopping:
                    raise KeyboardInterrupt("%s killed by signal %d" % (argv[0], -rc))
                return rc
            finally:
                if err_path:
                    err.close()

    def _reuse(self, b):
        old = self.old.get(self.rel(b.path))
        if old and old["kind"] == b.kind and runner.sha256_file(b.path) == old["sha256"]:
            return old
        return None

    def build_one(self, b):
        """Build b (or reuse a resumed build of it) and return its row."""
        old = self._reuse(b)
        if old:
            return old
        d = os.path.dirname(b.path)
        os.makedirs(d, exist_ok=True)
        if b.link is not None:
            if os.path.exists(b.path):
                os.remove(b.path)
            os.link(b.link.path, b.path)
            row = dict(self._row_of(b.link), seed=b.seed, path=self.rel(b.path), build_s=0.0)
            return _norm(row)
        bdir = os.path.join(d, "build")
        shutil.rmtree(bdir, ignore_errors=True)
        os.makedirs(bdir)
        iface, impl = self._paths(b.item)
        logp = os.path.join(d, "build.log")
        t0 = time.perf_counter()
        rc = self._call(compile_argv(b, self.mode, iface, impl, bdir), logp)
        dt = time.perf_counter() - t0
        shutil.rmtree(bdir, ignore_errors=True)
        if rc != 0 or not os.path.isfile(b.path):
            raise BuildError("%r failed (exit %d); see %s" % (b, rc, logp))
        facts = self.text_facts(b.path)
        expect, cov = "-", ""
        if b.arm.native and b.kind == "seed":
            expect, cov = self.check_layout(b)
        row = {"kind": b.kind, "arm": b.arm.name, "arm_idx": b.arm.idx,
               "backend": b.arm.backend, "item": b.item.name, "seed": b.seed,
               "place_seed": b.place_seed,
               "mode": self.mode if b.arm.native and b.kind != "noflag" else "",
               "sha256": runner.sha256_file(b.path), "text_sha256": facts["text_sha256"],
               "text_size": facts["text_size"], "expect_seed": expect, "build_s": dt,
               "path": self.rel(b.path), "cov": cov}
        return _norm(row)

    def _row_of(self, b):
        return self.done[self.rel(b.path)]

    def check_layout(self, b):
        """('ok' | 'fail' | 'error', covariate path or '') for a seeded
        native build."""
        d = os.path.dirname(b.path)
        argv = [sys.executable, LAYOUT_PY, b.path, "--expect-seed", str(b.place_seed),
                "--mode", self.mode]
        if b.arm.probe is not None:
            argv += ["--probe", b.arm.probe[0], "--probe-phase", str(b.arm.probe[1])]
        out = os.path.join(d, "layout.json" if self.static else "layout.txt")
        if self.static:
            argv += ["--json", "--loops"]
        rc = self._call(argv, out, os.path.join(d, "layout.err"))
        verdict = {0: "ok", 1: "fail", 3: "noprobe"}.get(rc, "error")
        cov = ""
        if self.static and rc in (0, 1, 3):
            with open(out) as fh:
                report = json.load(fh)
            st.write_json(os.path.join(d, "cov.json"), covariates(report))
            with open(out, "rb") as src, gzip.open(out + ".gz", "wb") as dst:
                shutil.copyfileobj(src, dst)
            os.remove(out)
            cov = self.rel(os.path.join(d, "cov.json"))
        return verdict, cov

    def stop(self):
        with self.lock:
            self.stopping = True
            for p in self.procs:
                p.terminate()

    def run(self, builds):
        """Run every build; returns their rows (as strings), in the order of
        builds.  Raises Abort when an abort condition holds and BuildError
        when a build fails."""
        self.done, self.total, self.reused = {}, len(builds), 0
        direct = [b for b in builds if b.link is None]
        linked = [b for b in builds if b.link is not None]
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=self.jobs)
        try:
            futs = {pool.submit(self.build_one, b): b for b in direct}
            for fut in concurrent.futures.as_completed(futs):
                self._record(futs[fut], fut.result())
            for b in linked:
                self._record(b, self.build_one(b))
        except BaseException:
            self.stop()
            pool.shutdown(wait=True, cancel_futures=True)
            raise
        pool.shutdown(wait=True)
        return [self.done[self.rel(b.path)] for b in builds]

    def _record(self, b, row):
        rel = self.rel(b.path)
        reused = self.old.get(rel) is row
        if not reused:
            self.tsv.append(row)
        self.done[rel] = row
        self.reused += reused
        n = len(self.done)
        if n % 10 == 0 or n == self.total:
            self.log("build: %d of %d done%s" % (n, self.total, " (%d reused)" % self.reused
                                                 if self.reused else ""))
        reasons = abort_reasons(list(self.done.values()), self.aa)
        if reasons:
            raise Abort(reasons)
