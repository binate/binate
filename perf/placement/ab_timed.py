"""Timed phase of a placement A/B experiment (ab.py run).

One round per seed.  In round r every workload item runs every arm back to
back, replicate by replicate, in schedule.round_orders(r, arms, reps) order,
with the round's stack pad placehash.stack_pad(seed) for every arm.  The run
of arm a is its seed-r binary from the store:

  bench        BIN N, its stdout the output;
  selfcompile  BIN <work flags> -I ... -L ... --build-dir B -o O SUBJECT/cmd/bnc
               with one fixed B (emptied before every run) and one fixed O,
               O's bytes the output.

Before the rounds, each item gets one untimed reference run (the base arm's
first-seed binary), which is also a warm-up.  Every timed run's output is then
checked: bench outputs must agree with the reference under the benchmark's
COMPARE (benchcfg.outputs_agree) and, at DEFAULT_N, with expected.txt (the
reference too); the self-compile's output must have the reference's SHA-256,
so every arm, seed and replicate produced the same compiler.  A failed check
(or a non-zero exit) is logged with out_ok=0, its output is copied to
failed/ in the work directory, and the experiment stops.

--max-load X holds each round, before its first run, until the 1-minute load
average is at most X (the runs themselves keep it near 1, so X must be above
that); it never pauses inside a round, whose runs must be contiguous in time
for its drift to cancel.  For the same reason, on --resume the rows of a
round that did not finish are moved to samples.dropped.tsv and the round is
run again from its start.  A round holding a failed output check counts as
unfinished, so the binary that failed is run, and checked, again.

Python standard library only.  The tests are in test_ab.py; nothing runs them
automatically:
  python3 -m unittest discover perf/placement
"""

import os
import shutil
import time

import ab_store as st
import benchcfg
import placehash
import runner
import schedule


# CPU seconds below which a reference run is reported as too short for its
# user time to mean much (a few clock ticks at the usual 100-1000 Hz).
SHORT_RUN = 0.05


class OutputMismatch(RuntimeError):
    """A run's output failed its check."""


def run_argv(item, binp, work_flags, paths, run_dir):
    """The timed command line of item's binary binp."""
    if item.kind == "bench":
        return [binp, str(item.n)]
    iface, impl = paths
    return ([binp] + list(work_flags)
            + ["-I", iface, "-L", impl, "--build-dir", os.path.join(run_dir, "build"),
               "-o", os.path.join(run_dir, "o", "bnc"), item.pkg])


def selfcompile_out(run_dir):
    return os.path.join(run_dir, "o", "bnc")


def prepare(item, run_dir):
    """Reset the self-compile's fixed build directory and output."""
    if item.kind != "selfcompile":
        return
    bdir = os.path.join(run_dir, "build")
    shutil.rmtree(bdir, ignore_errors=True)
    os.makedirs(bdir)
    os.makedirs(os.path.join(run_dir, "o"), exist_ok=True)
    out = selfcompile_out(run_dir)
    if os.path.exists(out):
        os.remove(out)


def read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


def expected_bytes(item):
    """expected.txt's bytes when item is a benchmark run at DEFAULT_N."""
    if item.kind != "bench" or not item.expected or str(item.n) != str(item.default_n):
        return None
    return read_bytes(item.expected)


def output_ok(item, sample, out, ref):
    """Whether a run's output passes: exit 0 and, for a benchmark, out agrees
    with the reference ref (and with expected.txt at DEFAULT_N); for the
    self-compile, the output's SHA-256 is ref."""
    if sample.rc != 0:
        return False
    if item.kind == "selfcompile":
        return bool(sample.out_hash) and sample.out_hash == ref
    if out is None or not benchcfg.outputs_agree(out, ref, item.compare):
        return False
    exp = expected_bytes(item)
    return exp is None or benchcfg.outputs_agree(out, exp, item.compare)


def wait_load(max_load, log, getload=os.getloadavg, sleep=time.sleep, poll=10.0):
    """Block until the 1-minute load average is at most max_load; returns
    the seconds waited."""
    waited = 0.0
    if max_load is None:
        return waited
    while True:
        load = getload()[0]
        if load <= max_load:
            if waited:
                log("load %.2f: resuming after %.0f s" % (load, waited))
            return waited
        if not waited:
            log("load %.2f above --max-load %.2f: waiting" % (load, max_load))
        sleep(poll)
        waited += poll


def round_keys(n_items, reps, k):
    return n_items * reps * k


def split_rounds(rows, seeds, n_items, reps, k):
    """(rows of finished rounds, rows of unfinished ones, finished round
    indices) of a resumed samples.tsv.  A round is finished when it has
    every run and every output check passed.  Raises ValueError when a
    row's seed is not the seed of its round."""
    by_round = {}
    for r in rows:
        rd = int(r["round"])
        if rd >= len(seeds) or int(r["seed"]) != seeds[rd]:
            raise ValueError("samples.tsv round %s ran seed %s, but this run's round %s is "
                             "seed %s" % (rd, r["seed"], rd,
                                          seeds[rd] if rd < len(seeds) else "none"))
        by_round.setdefault(rd, []).append(r)
    keep, drop, done = [], [], set()
    full = round_keys(n_items, reps, k)
    for rd in sorted(by_round):
        rs = by_round[rd]
        keys = {(r["bench"], r["rep"], r["arm_idx"]) for r in rs}
        if len(keys) == full and len(rs) == full and all(r["out_ok"] == "1" for r in rs):
            keep.extend(rs)
            done.add(rd)
        else:
            drop.extend(rs)
    return keep, drop, done


class Timed:
    """Runs the reference runs and the rounds; see the module doc."""

    def __init__(self, work, arms, items, seeds, reps, aslr, env, run_dir, work_flags,
                 subject_paths, samples, log, max_load=None, spawn=runner.spawn,
                 load=os.getloadavg, sleep=time.sleep):
        self.work, self.arms, self.items, self.seeds = work, arms, items, seeds
        self.reps, self.aslr, self.env, self.run_dir = reps, aslr, env, run_dir
        self.work_flags, self.paths, self.samples, self.log = work_flags, subject_paths, \
            samples, log
        self.max_load, self.spawn, self.load, self.sleep = max_load, spawn, load, sleep
        self.refs = {}

    def _bin(self, arm, seed, item):
        return st.bin_path(self.work, arm.idx, seed, item.sub)

    def _run(self, item, binp, pad):
        prepare(item, self.run_dir)
        out = os.path.join(self.run_dir, "stdout")
        hp = selfcompile_out(self.run_dir) if item.kind == "selfcompile" else None
        s = self.spawn(run_argv(item, binp, self.work_flags, self.paths, self.run_dir),
                       pad, self.run_dir, out, self.aslr, env=self.env, hash_path=hp)
        return s, (read_bytes(out) if item.kind == "bench" else None)

    def references(self):
        """Run (or, resumed, read back) each item's reference output."""
        ref_dir = os.path.join(self.work, "ref")
        os.makedirs(ref_dir, exist_ok=True)
        seed = self.seeds[0]
        for item in self.items:
            path = os.path.join(ref_dir, "%s.out" % item.name)
            data = read_bytes(path)
            if data is None:
                s, out = self._run(item, self._bin(self.arms[0], seed, item),
                                   placehash.stack_pad(seed))
                if s.rc != 0:
                    kept = self.keep_evidence(item, "reference-" + item.name)
                    raise OutputMismatch("reference run of %s (arm %s, seed %d) exited %d "
                                         "(output kept in %s)"
                                         % (item.name, self.arms[0].name, seed, s.rc, kept))
                data = out if item.kind == "bench" else s.out_hash.encode()
                if item.kind == "selfcompile" and not s.out_hash:
                    raise OutputMismatch("reference self-compile wrote no output")
                if s.user + s.sys < SHORT_RUN:
                    self.log("WARNING: the reference run of %s took %.4f s of CPU time: Linux "
                             "splits so short a run's user and system time by clock-tick "
                             "sampling, so its user time is unreliable (raise N)"
                             % (item.name, s.user + s.sys))
                exp = expected_bytes(item)
                if exp is not None and not benchcfg.outputs_agree(data, exp, item.compare):
                    kept = self.keep_evidence(item, "reference-" + item.name)
                    raise OutputMismatch("reference output of %s at N=%s does not match %s "
                                         "(output kept in %s)"
                                         % (item.name, item.n, item.expected, kept))
                with open(path, "wb") as fh:
                    fh.write(data)
                self.log("reference %s: %s" % (item.name, "matches expected.txt"
                                               if exp is not None else "recorded"))
            self.refs[item.name] = data if item.kind == "bench" else data.decode()

    def run(self, done=frozenset()):
        """Run every round not in done; returns the number of samples taken."""
        k, taken = len(self.arms), 0
        for r, seed in enumerate(self.seeds):
            if r in done:
                continue
            wait_load(self.max_load, self.log, self.load, self.sleep)
            pad = placehash.stack_pad(seed)
            orders = schedule.round_orders(r, k, self.reps)
            self.log("round %d of %d: seed %d, pad %d, orders %s"
                     % (r + 1, len(self.seeds), seed, pad,
                        " ".join(",".join(self.arms[a].name for a in o) for o in orders)))
            for item in self.items:
                for rep, order in enumerate(orders):
                    for pos, ai in enumerate(order):
                        self._timed(r, seed, rep, pos, pad, item, self.arms[ai])
                        taken += 1
        return taken

    def _timed(self, r, seed, rep, pos, pad, item, arm):
        s, out = self._run(item, self._bin(arm, seed, item), pad)
        ok = output_ok(item, s, out, self.refs[item.name])
        row = {"round": r, "seed": seed, "rep": rep, "pad": pad, "aslr": self.aslr,
               "workload": item.kind, "bench": item.name,
               "n": item.n if item.kind == "bench" else "", "arm": arm.name,
               "arm_idx": arm.idx, "pos": pos, "out_ok": ok}
        for f in runner.FIELDS:
            if f in st.SAMPLE_COLS:
                row[f] = getattr(s, f)
        self.samples.append(row)
        if not ok:
            kept = self.keep_evidence(item, "r%d-s%d-rep%d-%s-%s" % (r, seed, rep, arm.name,
                                                                     item.name))
            raise OutputMismatch("round %d, seed %d, rep %d, arm %s, %s: %s (output kept in %s)"
                                 % (r, seed, rep, arm.name, item.name,
                                    "exit %d" % s.rc if s.rc else "wrong output", kept))

    def keep_evidence(self, item, tag):
        """Copy a failed run's stdout, stderr and (self-compile) output into
        work/failed/, since the run directory does not outlive the driver."""
        d = os.path.join(self.work, "failed")
        os.makedirs(d, exist_ok=True)
        srcs = [("stdout", os.path.join(self.run_dir, "stdout")),
                ("stderr", os.path.join(self.run_dir, "stdout.err"))]
        if item.kind == "selfcompile":
            srcs.append(("bin", selfcompile_out(self.run_dir)))
        for suffix, src in srcs:
            if os.path.exists(src):
                shutil.copyfile(src, os.path.join(d, "%s.%s" % (tag, suffix)))
        return os.path.join(d, tag + ".*")
