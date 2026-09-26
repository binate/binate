#!/usr/bin/env python3
"""Measure what each IR optimization pass costs and buys under the bytecode VM.

Under bni the passes run on every load (there is no ahead-of-time step), so a
pass is worth running in the VM only if the run time it saves outweighs the
load time it adds.  This driver measures both, per pass, with bni's
-f<pass> / -fno-<pass> switches:

  - LOAD cost: bni loading a large program (cmd/bnc, run as `--version`, so
    the time is almost all parse + check + IR + passes + lowering).
  - RUN benefit: the benchmarks repo's programs (binary-trees, n-body, ...) at
    VM-sized inputs.  These times include bni loading the benchmark (small
    programs, so a small share), so a pass's load cost is not fully excluded.

Pass configurations:
  O0        no pass
  O2        every pass
  cum:<p>   the passes up to and including <p>, in pipeline order
  loo:<p>   every pass except <p>

Timing follows explorations/perf-optimization-guide.md: user CPU of the child
(wait4 rusage, not wall clock), every configuration of a round interleaved with
the others, the order reversed on alternate rounds so drift cancels, the median
over rounds reported with the min-max range beside it (the spread of the O0 row
is the noise floor).  Use an even number of rounds so the reversals balance.
Each run's output is checked against the O0 run of the same workload; a
configuration whose output differs, or that exits nonzero, is still timed but
marked BAD, and the script exits 1.

Usage:
  perf/vm-pass-costs.py --bni <bni> --bench <benchmarks-repo>/bench [--rounds N]
                        [--configs O0,O2,cum,loo] [--only <workload>,...] [--log F]

Requires python3.  The bni is whatever you pass (build it the way the
measurement should reflect, e.g. at bnc -O2 like the release scripts).
"""

import argparse
import os
import statistics
import subprocess
import sys

BINATE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Pipeline order (iropt PASS_*); `bnc --list-opt-passes` prints the same list.
PASSES = ["inline", "sroa", "mem2reg", "dead-phi", "load-fwd", "field-load-fwd",
          "simplify", "div-check-elim", "bce-const", "bce-loop", "bce-redundant",
          "licm", "fuse-madd"]

# name -> (argument, VM-sized input).  Sized to run ~1-4 s under bni -O 0.
BENCHMARKS = [
    ("binary-trees", "11"),
    ("fannkuch-redux", "8"),
    ("fasta", "25000"),
    ("mandelbrot", "300"),
    ("n-body", "30000"),
    ("record-churn", "800"),
    ("richards", "50"),
    ("spectral-norm", "250"),
]


def paths(kind, prepend=None):
    cmd = [os.path.join(BINATE_DIR, "scripts", "binate-paths.sh"), "--" + kind,
           "--base", BINATE_DIR]
    if prepend:
        cmd += ["--prepend", prepend]
    return subprocess.check_output(cmd, text=True).strip()


def workloads(bench_dir, only):
    out = [("load:cmd/bnc", ["-I", paths("iface"), "-L", paths("impl"),
                             "-main-dir", os.path.join(BINATE_DIR, "cmd", "bnc"),
                             "--", "--version"])]
    for name, n in BENCHMARKS:
        root = os.path.join(bench_dir, name, "binate")
        out.append((name, ["-I", paths("iface", root), "-L", paths("impl", root),
                           "-main-dir", os.path.join(root, "cmd", name), "--", n]))
    if only:
        out = [w for w in out if w[0] in only]
    return out


def configs(kinds):
    out = []
    if "O0" in kinds:
        out.append(("O0", []))
    if "O2" in kinds:
        out.append(("O2", ["-O", "2"]))
    if "cum" in kinds:
        for i, p in enumerate(PASSES):
            out.append(("cum:" + p, ["-f" + q for q in PASSES[:i + 1]]))
    if "loo" in kinds:
        for p in PASSES:
            out.append(("loo:" + p, ["-O", "2", "-fno-" + p]))
    return out


def run(argv):
    """Run argv; return (user CPU seconds, exit status, stdout+stderr)."""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        os.dup2(w, 1)
        os.dup2(w, 2)
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)
    os.close(w)
    chunks = []
    while True:
        b = os.read(r, 65536)
        if not b:
            break
        chunks.append(b)
    os.close(r)
    _, status, ru = os.wait4(pid, 0)
    return ru.ru_utime, status, b"".join(chunks)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bni", required=True)
    ap.add_argument("--bench", required=True, help="the benchmarks repo's bench/ dir")
    ap.add_argument("--rounds", type=int, default=4, help="an even number")
    ap.add_argument("--configs", default="O0,O2,cum,loo")
    ap.add_argument("--only", default="", help="comma-separated workload names")
    ap.add_argument("--log", default="")
    a = ap.parse_args()
    if a.rounds < 1 or a.rounds % 2 != 0:
        ap.error("--rounds must be a positive even number (forward and reversed rounds balance)")

    ws = workloads(a.bench, set(filter(None, a.only.split(","))))
    cs = configs(set(a.configs.split(",")))
    if not any(c[0] == "O0" for c in cs):
        cs.insert(0, ("O0", []))  # the reference for outputs and ratios
    log = open(a.log, "w") if a.log else None

    times = {}      # (workload, config) -> [seconds]
    bad = set()     # (workload, config) whose output differs from O0
    ref = {}        # workload -> O0 output
    order = [(w, c) for w in ws for c in cs]
    for rnd in range(a.rounds):
        seq = order if rnd % 2 == 0 else list(reversed(order))
        for (wname, wargs), (cname, cargs) in seq:
            t, status, out = run([a.bni] + cargs + wargs)
            key = (wname, cname)
            if cname == "O0" and wname not in ref:
                ref[wname] = out
            if status != 0 or (wname in ref and out != ref[wname]):
                bad.add(key)
            times.setdefault(key, []).append(t)
            line = "%d\t%s\t%s\t%.3f\t%s" % (rnd, wname, cname, t, "BAD" if key in bad else "ok")
            print(line, file=sys.stderr)
            if log:
                print(line, file=log)
                log.flush()

    # Report: median user seconds [min-max], and each config's ratio of medians
    # to O0 per workload.
    cnames = [c[0] for c in cs]
    wnames = [w[0] for w in ws]
    print("| config | " + " | ".join(wnames) + " |")
    print("|---|" + "---|" * len(wnames))
    for c in cnames:
        cells = []
        for w in wnames:
            ts = times[(w, c)]
            med = statistics.median(ts)
            base = statistics.median(times[(w, "O0")])
            ratio = "%.2f" % (med / base) if base > 0 else "n/a"
            mark = " BAD" if (w, c) in bad else ""
            cells.append("%.2fs [%.2f-%.2f] (%s)%s" % (med, min(ts), max(ts), ratio, mark))
        print("| %s | %s |" % (c, " | ".join(cells)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
