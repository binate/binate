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

Pass configurations (each spelled out as a full set of -f / -fno flags, so
bni's own default does not matter):
  O0        no pass
  VM        bni's default pass set (no flags)
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

With --instructions, each configuration's workloads are instead run once under
callgrind and the table reports instructions executed (deterministic, so it
resolves load costs far below the timing noise; outputs are not checked).
Meant for the load workload (--only load:cmd/bnc); --jobs runs that many
callgrind processes at once, which does not perturb instruction counts.

With --log F, every finished run is appended to F as it completes (round,
workload, config, result, a hash of its output); --resume reads F back and runs
only what is missing, so an interrupted measurement continues where it stopped.

Usage:
  perf/vm-pass-costs.py --bni <bni> --bench <benchmarks-repo>/bench [--rounds N]
                        [--configs O0,O2,cum,loo] [--only <workload>,...]
                        [--log F [--resume]]
  perf/vm-pass-costs.py --bni <bni> --bench <benchmarks-repo>/bench --instructions
                        [--jobs N] [--configs ...] [--only ...] [--log F [--resume]]

Requires python3.  The bni is whatever you pass (build it the way the
measurement should reflect, e.g. at bnc -O2 like the release scripts).
"""

import argparse
import concurrent.futures
import hashlib
import os
import re
import statistics
import subprocess
import sys

BINATE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Pipeline order (iropt PASS_*); `bnc --list-opt-passes` prints the same list.
PASSES = ["inline", "sroa", "mem2reg", "dead-phi", "load-fwd", "field-load-fwd",
          "dead-slot", "dead-store", "simplify", "fold-branch", "div-check-elim",
          "bce-const", "bce-loop", "bce-redundant", "licm", "fuse-madd", "sink-extract"]

# name -> (argument, VM-sized input).  Sized to run ~1-4 s with no pass.
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


def passes_flags(on):
    """The flags that run exactly the passes in `on`."""
    return [("-f" if p in on else "-fno-") + p for p in PASSES]


def configs(kinds):
    out = []
    if "O0" in kinds:
        out.append(("O0", passes_flags(set())))
    if "VM" in kinds:
        out.append(("VM", []))
    if "O2" in kinds:
        out.append(("O2", passes_flags(set(PASSES))))
    if "cum" in kinds:
        for i, p in enumerate(PASSES):
            out.append(("cum:" + p, passes_flags(set(PASSES[:i + 1]))))
    if "loo" in kinds:
        for p in PASSES:
            out.append(("loo:" + p, passes_flags(set(PASSES) - {p})))
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


def instructions(argv):
    """Instructions argv executes, counted by callgrind."""
    _, status, out = run(["/usr/bin/env", "valgrind", "--tool=callgrind",
                          "--callgrind-out-file=/dev/null"] + argv)
    m = re.search(rb"Collected : (\d+)", out)
    if not m:
        raise RuntimeError("no callgrind count (status %d): %s" % (status, out[-2000:]))
    return int(m.group(1)), status


def read_log(a):
    """The lines of a previous --log, split on tabs, when resuming."""
    if not (a.resume and os.path.exists(a.log)):
        return []
    with open(a.log) as f:
        return [l.rstrip("\n").split("\t") for l in f if l.strip()]


def open_log(a):
    return open(a.log, "a" if a.resume else "w") if a.log else None


def emit(log, fields):
    line = "\t".join(str(x) for x in fields)
    print(line, file=sys.stderr)
    if log:
        print(line, file=log)
        log.flush()


def report_instructions(a, ws, cs):
    counts = {}     # (workload, config) -> (instructions, exit status)
    for f in read_log(a):
        counts[(f[0], f[1])] = (int(f[2]), int(f[3]))
    log = open_log(a)
    jobs = [(w, c) for w in ws for c in cs if (w[0], c[0]) not in counts]
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(instructions, [a.bni] + c[1] + w[1]): (w[0], c[0]) for w, c in jobs}
        for f in concurrent.futures.as_completed(futs):
            n, status = f.result()
            counts[futs[f]] = (n, status)
            emit(log, [futs[f][0], futs[f][1], n, status])
    # Report: instructions (billions), ratio to O0, and the step from the
    # previous row (for the cum: rows, the cost of that pass given the ones
    # before it).
    wnames = [w[0] for w in ws]
    print("| config | " + " | ".join(wnames) + " |")
    print("|---|" + "---|" * len(wnames))
    prev = None
    for cname, _ in cs:
        cells = []
        for w in wnames:
            n, status = counts[(w, cname)]
            base = counts[(w, "O0")][0]
            step = ""
            if prev is not None and cname.startswith("cum:"):
                step = " %+.2f" % ((n - counts[(w, prev)][0]) / 1e9)
            mark = " exit=%d" % status if status != 0 else ""
            cells.append("%.2fG (%.3f)%s%s" % (n / 1e9, n / base, step, mark))
        print("| %s | %s |" % (cname, " | ".join(cells)))
        prev = cname if cname.startswith("cum:") or cname == "O0" else prev
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--bni", required=True)
    ap.add_argument("--bench", required=True, help="the benchmarks repo's bench/ dir")
    ap.add_argument("--rounds", type=int, default=4, help="an even number")
    ap.add_argument("--configs", default="O0,VM,O2,cum,loo")
    ap.add_argument("--only", default="", help="comma-separated workload names")
    ap.add_argument("--log", default="")
    ap.add_argument("--instructions", action="store_true",
                    help="count instructions under callgrind instead of timing")
    ap.add_argument("--jobs", type=int, default=1, help="parallel callgrind runs")
    ap.add_argument("--resume", action="store_true",
                    help="continue the measurement recorded in --log")
    a = ap.parse_args()
    if a.resume and not a.log:
        ap.error("--resume needs --log")
    if a.rounds < 1 or a.rounds % 2 != 0:
        ap.error("--rounds must be a positive even number (forward and reversed rounds balance)")

    ws = workloads(a.bench, set(filter(None, a.only.split(","))))
    cs = configs(set(a.configs.split(",")))
    if not any(c[0] == "O0" for c in cs):
        cs.insert(0, ("O0", passes_flags(set())))  # the reference for outputs and ratios
    if a.instructions:
        return report_instructions(a, ws, cs)
    times = {}      # (workload, config) -> [seconds]
    runs = []       # (workload, config, exit status, output hash)
    done = set()    # (round, workload, config) already measured
    for f in read_log(a):
        rnd, wname, cname, t, status, digest = f
        done.add((int(rnd), wname, cname))
        times.setdefault((wname, cname), []).append(float(t))
        runs.append((wname, cname, int(status), digest))
    log = open_log(a)
    order = [(w, c) for w in ws for c in cs]
    for rnd in range(a.rounds):
        seq = order if rnd % 2 == 0 else list(reversed(order))
        for (wname, wargs), (cname, cargs) in seq:
            if (rnd, wname, cname) in done:
                continue
            t, status, out = run([a.bni] + cargs + wargs)
            digest = hashlib.sha1(out).hexdigest()
            times.setdefault((wname, cname), []).append(t)
            runs.append((wname, cname, status, digest))
            emit(log, [rnd, wname, cname, "%.3f" % t, status, digest])

    # A run is BAD if it exited nonzero or its output differs from the O0 run
    # of the same workload.
    ref = {w: d for w, c, _, d in runs if c == "O0"}
    bad = {(w, c) for w, c, status, d in runs if status != 0 or d != ref.get(w)}

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
