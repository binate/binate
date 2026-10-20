#!/usr/bin/env python3
"""Placement-randomized A/B timing of bnc builds.

  ab.py run --work DIR --arm NAME=BNC [--arm-flags NAME='...']
            [--arm-backend NAME=llvm] ...
            (--workload selfcompile --subject TREE [--work-flags '...']
             | --workload bench --subject TREE --bench BENCH [--only B,...] [--n B=N])
            --seeds 1-40 [--reps 2] [--jobs 4] [--mode phase|shift]
            [--aslr off|on] [--aa same|salted] [--probe SYM --probe-phases P,...]
            [--static-report] [--resume] [--dry-run] [--max-load X]
            [--tmpdir DIR] [--drop-caches auto|on|off] [--allow-short-runs]

Compares compilers ("arms"; the first is the base) on how fast the code they
generate runs, with the code's placement randomized: every round seed S gives
each native arm a build with -fnative-place-seed=S (see ab_build), so a
difference that only one placement produces averages out over the seeds
instead of masquerading as the effect of the change.  The workload is either
the built bnc compiling SUBJECT/cmd/bnc (selfcompile) or the benchmarks under
BENCH, the benchmarks repository's bench/ directory (bench); SUBJECT is the
Binate tree whose scripts/binate-paths.sh gives the package search paths.

The experiment runs in two phases: an untimed, parallel build phase that
aborts on the checks ab_build lists, and a timed phase (ab_timed) of one round
per seed, each arm run back to back in a Williams-balanced order (schedule)
with the same stack pad, in a scrubbed environment with ASLR off (runner).
Everything lands in DIR (ab_store): builds.tsv, samples.tsv, meta.json.
stats.py DIR analyses it.

  --aa same     A/A: arms may build identical binaries (the run-noise floor)
  --aa salted   A/A: arm i is placed with placehash.salted_seed applied i
                times, so identical compilers still get different placements
  --probe SYM --probe-phases P,...
                time one function's placement: the one --arm becomes one arm
                per phase P (NAME.pPP, the first the base), each built with
                -fnative-place-probe=SYM -fnative-place-probe-phase=P on top
                of the round's seed, so only SYM moves between the arms;
                layout.py checks SYM's phase in every seeded build, and a SYM
                that names no function stops the experiment (see ab_config)
  --resume      continue an interrupted experiment in DIR (same configuration,
                sources, timed environment, stack limit and personality, see
                ab_config; the seed list may be extended)
  --dry-run     print the builds and the run schedule; build and run nothing
  --max-load X  hold each round until the 1-minute load is at most X
  --static-report  also keep layout.py's report of every seeded build and
                its covariates, which stats.py relates to per-seed timing
  --tmpdir DIR  the tmpfs directory the runs use for TMPDIR and their output
                (default: a fresh directory under the first tmpfs mount)
  --drop-caches auto|on|off
                drop the page cache (Linux, as root) between the build and
                timed phases, so every binary is paged in when it first runs,
                in the balanced run order.  Without it, in A/A runs of one
                compiler on the native self-compile (a 14 MB-text bnc), the
                second arm ran ~0.6-1.9% slower in all four experiments; with
                it, in neither of two.  auto (the default) drops when it can
                and warns when it cannot; on makes a failed drop an error
  --allow-short-runs  only warn when an item's reference run uses less than
                ab_timed.MIN_RUN_CPU seconds of CPU time; without it that
                stops the experiment, since so short a run's user time is
                unreliable (raise the item's N with --n instead)

Exit status: 0 done; 1 a build or tool failed; 2 bad usage; 3 a check stopped
the experiment (build checks, output checks, a too-short reference run, ASLR,
stack preflight); 130
interrupted.  LLVM arms are allowed and are reported as "placement not
randomized".

Modules: ab_config (the command line), ab_build (build phase and its abort
checks), ab_timed (timed phase and output checks), ab_store (the work
directory), runner (one timed run, ASLR, stack preflight), schedule (run
order), benchcfg (benchmark settings), binfile (section facts).

Python standard library only.  The tests are in test_ab.py; nothing runs them
automatically:
  python3 -m unittest discover perf/placement
"""

import argparse
import os
import resource
import shlex
import shutil
import signal
import sys
import time

import ab_build as bld
import ab_store as st
import ab_timed as tm
import placehash
import runner
import schedule
from ab_config import DEFAULT_WORK_FLAGS, Config, ConfigError


class Log:
    """Timestamped messages to stderr and, given a path, to that file."""

    def __init__(self, path=None):
        self.fh = open(path, "a") if path else None

    def __call__(self, msg):
        line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
        print(line, file=sys.stderr, flush=True)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()

    def close(self):
        if self.fh:
            self.fh.close()
            self.fh = None


def not_randomized(arm):
    return "" if arm.native else "  (LLVM backend: placement not randomized)"


def dry_run(cfg, out=None):
    w = (out or sys.stdout).write
    a = cfg.args
    w("ab.py dry run: nothing is built or run; work dir %s\n" % cfg.work)
    w("arms (base first):\n")
    for arm in cfg.arms:
        probe = "  (probe %s at phase %d)" % arm.probe if arm.probe is not None else ""
        w("  a%02d %-12s %-6s %s %s%s%s\n" % (arm.idx, arm.name, arm.backend, arm.bnc,
                                               " ".join(arm.flags), not_randomized(arm), probe))
    w("items:\n")
    for it in cfg.items:
        if it.kind == "bench":
            w("  %-16s N=%s compare=%s%s\n" % (it.name, it.n, it.compare,
                                               "  (checked against expected.txt)"
                                               if tm.expected_bytes(it) is not None else ""))
        else:
            w("  self-compile of %s with: %s\n" % (it.pkg, " ".join(cfg.work_flags)))
    builds = bld.plan_builds(cfg.work, cfg.arms, cfg.items, cfg.seeds, a.aa)
    w("builds (%d; mode %s, --aa %s):\n" % (len(builds), a.mode, a.aa or "-"))
    paths = {}
    for b in builds:
        if b.link is not None:
            w("  %s  link of %s\n" % (os.path.relpath(b.path, cfg.work),
                                     os.path.relpath(b.link.path, cfg.work)))
            continue
        if b.item.root not in paths:
            paths[b.item.root] = bld.search_paths(cfg.subject, b.item.root)
        argv = bld.compile_argv(b, a.mode, *paths[b.item.root],
                                os.path.join(os.path.dirname(b.path), "build"))
        w("  %s\n" % " ".join(shlex.quote(x) for x in argv))
    k = len(cfg.arms)
    total = len(cfg.seeds) * len(cfg.items) * a.reps * k
    w("timed runs: %d rounds x %d items x %d reps x %d arms = %d (ASLR %s)\n"
      % (len(cfg.seeds), len(cfg.items), a.reps, k, total, a.aslr))
    for r, seed in enumerate(cfg.seeds):
        orders = schedule.round_orders(r, k, a.reps)
        w("  round %d seed %d pad %d: %s\n"
          % (r, seed, placehash.stack_pad(seed),
             " | ".join(" ".join(cfg.arms[i].name for i in o) for o in orders)))


def summary(cfg, rows, out=None):
    w = (out or sys.stderr).write
    w("summary: %d samples in %s\n" % (len(rows), os.path.join(cfg.work, "samples.tsv")))
    for it in cfg.items:
        for arm in cfg.arms:
            us = sorted(float(r["user"]) for r in rows
                        if r["bench"] == it.name and r["arm"] == arm.name)
            bad = sum(1 for r in rows if r["bench"] == it.name and r["arm"] == arm.name
                      and r["out_ok"] != "1")
            med = us[len(us) // 2] if us else float("nan")
            w("  %-16s %-12s n=%-4d median user %.4f s%s%s\n"
              % (it.name, arm.name, len(us), med, "  %d BAD OUTPUTS" % bad if bad else "",
                 not_randomized(arm)))
    w("analyse with: %s %s\n" % (os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                               "stats.py"), cfg.work))


def git_heads(cfg):
    tool = os.path.dirname(os.path.abspath(__file__))
    gits = {"subject": st.git_head(cfg.subject), "tool": st.git_head(tool)}
    if cfg.args.bench:
        gits["bench"] = st.git_head(os.path.realpath(cfg.args.bench))
    return gits


def open_work(cfg):
    """meta.json for a fresh or resumed experiment; ConfigError otherwise."""
    meta_path = os.path.join(cfg.work, "meta.json")
    if cfg.args.resume:
        if not os.path.isfile(meta_path):
            raise ConfigError("--resume: %s has no meta.json" % cfg.work)
        meta = st.read_json(meta_path)
        rec = cfg.record()
        diff = st.config_diff(meta["config"], rec)
        if diff:
            raise ConfigError("--resume: the configuration differs in: %s" % ", ".join(diff))
        meta["config"] = rec
        meta.setdefault("resumed", []).append({"at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                                               "git": git_heads(cfg)})
        return meta
    if os.path.isdir(cfg.work) and os.listdir(cfg.work):
        raise ConfigError("%s is not empty (use --resume to continue it)" % cfg.work)
    os.makedirs(cfg.work, exist_ok=True)
    return {"config": cfg.record(), "host": st.host_info(), "git": git_heads(cfg),
            "compilers": {a.name: a.sha for a in cfg.arms},
            "started": time.strftime("%Y-%m-%dT%H:%M:%S")}


def experiment(cfg, log, meta):
    """Both phases; raises on any stop."""
    a = cfg.args
    meta_path = os.path.join(cfg.work, "meta.json")
    aslr = runner.set_aslr(a.aslr, log=log)
    meta["aslr"] = aslr
    root, made = cfg.tmp_root()
    env = cfg.timed_env()
    run_dir = os.path.join(root, "run")
    for d in (env["TMPDIR"], env["HOME"], run_dir):
        os.makedirs(d, exist_ok=True)
    on_tmpfs = runner.fs_type(root) == "tmpfs"
    if not on_tmpfs:
        log("WARNING: %s is not on tmpfs" % root)
    bits = cfg.record()["personality"]
    if bits:
        log("WARNING: personality(2) flags %#x are set and every timed run inherits them "
            "(setarch -L, for one, changes the mmap layout)" % bits)
    if resource.getrlimit(resource.RLIMIT_STACK)[0] == resource.RLIM_INFINITY:
        log("WARNING: the stack size limit is unlimited, which gives Linux processes the "
            "legacy (bottom-up) mmap layout")
    # The builds are untimed, so they keep the invoking PATH and HOME (bnc
    # finds clang, layout.py finds llvm-objdump, through PATH).
    build_env = runner.base_env(os.environ.get("PATH", runner.FIXED_PATH),
                                os.environ.get("HOME", "/"), env["TMPDIR"])
    meta.update(env=env, build_env=build_env, tmp_root=root, tmp_on_tmpfs=on_tmpfs,
                run_dir=run_dir)
    st.write_json(meta_path, meta)
    try:
        meta["preflight"] = runner.preflight(env, run_dir, aslr,
                                             pad=placehash.stack_pad(cfg.seeds[0]), log=log)
        st.write_json(meta_path, meta)
        builds_log = st.TsvLog(os.path.join(cfg.work, "builds.tsv"), st.BUILD_COLS)
        builder = bld.Builder(cfg.work, cfg.subject, a.mode, a.aa, a.static_report, a.jobs,
                              build_env, log, builds_log,
                              st.read_tsv(builds_log.path, st.BUILD_COLS))
        plan = bld.plan_builds(cfg.work, cfg.arms, cfg.items, cfg.seeds, a.aa)
        log("build phase: %d builds, %d at a time" % (len(plan), a.jobs))
        # One row per build, in plan order, even after a resume rebuilt some.
        builds_log.rewrite(builder.run(plan))
        if a.drop_caches != "off":
            try:
                runner.drop_page_cache()
                log("page cache dropped")
            except OSError as e:
                if a.drop_caches == "on":
                    raise
                log("WARNING: could not drop the page cache (%s): binaries that stay in the "
                    "page cache since their build can bias a large program's timings between "
                    "arms; run as root, or pass --drop-caches off" % e)
        for arm in cfg.arms:
            if not arm.native:
                log("arm %s:%s" % (arm.name, not_randomized(arm)))
        samples_path = os.path.join(cfg.work, "samples.tsv")
        old = st.read_tsv(samples_path, st.SAMPLE_COLS)
        keep, drop, done = tm.split_rounds(old, cfg.seeds, len(cfg.items), a.reps,
                                           len(cfg.arms))
        samples = st.TsvLog(samples_path, st.SAMPLE_COLS)
        if drop:
            dropped = st.TsvLog(os.path.join(cfg.work, "samples.dropped.tsv"), st.SAMPLE_COLS)
            for r in drop:
                dropped.append(r)
            samples.rewrite(keep)
            log("resume: %d samples of unfinished rounds moved to samples.dropped.tsv"
                % len(drop))
        timed = tm.Timed(cfg.work, cfg.arms, cfg.items, cfg.seeds, a.reps, aslr, env, run_dir,
                         cfg.work_flags, bld.search_paths(cfg.subject), samples, log,
                         a.max_load, allow_short=a.allow_short_runs)
        timed.references()
        log("timed phase: %d rounds (%d already done)" % (len(cfg.seeds), len(done)))
        timed.run(done)
    finally:
        if made:
            shutil.rmtree(root, ignore_errors=True)


def _sigterm(signum, frame):
    raise KeyboardInterrupt


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="ab.py", description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="build and time an experiment")
    r.add_argument("--work", required=True, help="the experiment directory")
    r.add_argument("--arm", action="append", required=True, metavar="NAME=BNC",
                   help="an arm and its compiler (repeatable; the first is the base)")
    r.add_argument("--arm-flags", action="append", default=[], metavar="NAME=FLAGS",
                   help="extra bnc flags for an arm's builds")
    r.add_argument("--arm-backend", action="append", default=[], metavar="NAME=BACKEND",
                   help="native (the default) or llvm")
    r.add_argument("--workload", required=True, choices=["selfcompile", "bench"])
    r.add_argument("--subject", required=True, metavar="TREE",
                   help="the Binate tree giving the search paths (and cmd/bnc)")
    r.add_argument("--work-flags", metavar="FLAGS",
                   help="selfcompile: flags of the timed compile (default %r); a single "
                        "flag starting with '-' needs the --work-flags=FLAG form"
                        % DEFAULT_WORK_FLAGS)
    r.add_argument("--bench", metavar="DIR", help="bench: the benchmarks' bench/ directory")
    r.add_argument("--only", action="append", default=[], metavar="B,...",
                   help="bench: run only these benchmarks")
    r.add_argument("--n", action="append", default=[], metavar="B=N",
                   help="bench: size for benchmark B (default its DEFAULT_N)")
    r.add_argument("--seeds", required=True, metavar="SPEC", help="round seeds, e.g. 1-40")
    r.add_argument("--reps", type=int, default=2, help="replicates per arm and round")
    r.add_argument("--jobs", type=int, default=4, help="parallel builds")
    r.add_argument("--mode", choices=sorted(placehash.MODES), default="phase")
    r.add_argument("--aslr", choices=["off", "on"], default="off")
    r.add_argument("--aa", choices=["same", "salted"])
    r.add_argument("--probe", metavar="SYM",
                   help="probe the function with this mangled symbol (one arm per phase)")
    r.add_argument("--probe-phases", metavar="P,...",
                   help="the probe phases, e.g. 0,16,32,48 (x86-64) or 0,4,...,60 (Arm)")
    r.add_argument("--static-report", action="store_true")
    r.add_argument("--resume", action="store_true")
    r.add_argument("--dry-run", action="store_true")
    r.add_argument("--max-load", type=float, metavar="X")
    r.add_argument("--drop-caches", choices=("auto", "on", "off"), default="auto",
                   help="drop the page cache (Linux, root) after the build phase, so each "
                        "binary is paged in when it first runs (default auto: when possible)")
    r.add_argument("--allow-short-runs", action="store_true",
                   help="only warn, instead of stopping, when a reference run uses less than "
                        "%.1f s of CPU time" % tm.MIN_RUN_CPU)
    r.add_argument("--tmpdir", metavar="DIR")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        cfg = Config(args)
    except (ConfigError, OSError) as e:
        print("ab.py: %s" % e, file=sys.stderr)
        return 2
    if args.dry_run:
        dry_run(cfg)
        return 0
    try:
        meta = open_work(cfg)
    except (ConfigError, OSError) as e:
        print("ab.py: %s" % e, file=sys.stderr)
        return 2
    log = Log(os.path.join(cfg.work, "log.txt"))
    meta_path = os.path.join(cfg.work, "meta.json")
    old_term = signal.signal(signal.SIGTERM, _sigterm)
    status, why = 0, None
    try:
        experiment(cfg, log, meta)
    except KeyboardInterrupt:
        status, why = 130, "interrupted"
    except bld.Abort as e:
        status, why = 3, "; ".join(e.args[0])
    except (tm.OutputMismatch, tm.RunTooShort, runner.AslrError, runner.PreflightError) as e:
        status, why = 3, str(e)
    except (bld.BuildError, OSError, RuntimeError, ValueError) as e:
        status, why = 1, str(e)
    finally:
        signal.signal(signal.SIGTERM, old_term)
    if status == 3:
        for line in why.split("; "):
            log("ABORT: %s" % line)
    elif status:
        log("STOPPED: %s" % why)
    meta["ended"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    meta["status"] = {0: "done", 1: "failed", 3: "aborted", 130: "interrupted"}[status]
    meta.pop("why", None)
    if why:
        meta["why"] = why
    st.write_json(meta_path, meta)
    log.close()
    summary(cfg, st.read_tsv(os.path.join(cfg.work, "samples.tsv")))
    return status


if __name__ == "__main__":
    sys.exit(main())
