"""Command-line configuration of a placement A/B experiment (ab.py run).

Config validates the parsed arguments into arms (ab_build.Arm: name, compiler
and its SHA-256, extra flags, backend) and workload items (ab_build.Item: the
self-compile of SUBJECT/cmd/bnc, or each benchmark with its size, COMPARE
rule and expected.txt), and record() gives the part of the configuration a
resumed experiment must share.  Every problem raises ConfigError.

Paths are resolved through symlinks, so every spelling of the work directory,
SUBJECT or BENCH gives the same store paths and timed command lines (whose
lengths move the initial stack).  Besides the options, the record holds what
else decides where a timed run's stack and mappings land, or what it runs:
the timed environment, the stack size limit (with ASLR off it sets the mmap
base, and unlimited switches Linux to the legacy layout), the other
personality(2) flags, and a digest of the sources the builds read (SUBJECT's
tree and each benchmark's binate/ tree, ab_store.source_digest) and of each
expected.txt.  A resume with any of them changed would mix builds of
different code, or different address layouts, in one experiment.

Python standard library only.  The tests are in test_ab.py; nothing runs them
automatically:
  python3 -m unittest discover perf/placement
"""

import hashlib
import os
import re
import resource
import shlex

import ab_build as bld
import ab_store as st
import benchcfg
import runner

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]*$")
DEFAULT_WORK_FLAGS = "--backend native --linker bnld"


class ConfigError(ValueError):
    """The command line does not describe a runnable experiment."""


def parse_seeds(spec):
    """Seeds from '1-40', '3,5,9-12' ...; in the order given, no repeats,
    each in 1..ab_store.MAX_SEED."""
    out = []
    for part in spec.split(","):
        m = re.match(r"^\s*(\d+)(?:\s*-\s*(\d+))?\s*$", part)
        if not m:
            raise ConfigError("bad --seeds part %r" % part)
        lo = int(m.group(1))
        hi = int(m.group(2)) if m.group(2) else lo
        if hi < lo:
            raise ConfigError("bad --seeds range %r" % part)
        out.extend(range(lo, hi + 1))
    if len(set(out)) != len(out):
        raise ConfigError("--seeds repeats a seed")
    bad = [s for s in out if not 1 <= s <= st.MAX_SEED]
    if bad:
        raise ConfigError("seeds must be in 1..%d (seed 0 is the unplaced control): %s"
                          % (st.MAX_SEED, bad[:5]))
    return out


def _pairs(values, what):
    out = {}
    for v in values:
        name, sep, val = v.partition("=")
        if not sep or not name:
            raise ConfigError("%s wants NAME=VALUE, not %r" % (what, v))
        if name in out:
            raise ConfigError("%s given twice for %s" % (what, name))
        out[name] = val
    return out


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def make_arms(args):
    arms = []
    flags = _pairs(args.arm_flags, "--arm-flags")
    backs = _pairs(args.arm_backend, "--arm-backend")
    for i, (name, bnc) in enumerate(_pairs(args.arm, "--arm").items()):
        if not NAME_RE.match(name):
            raise ConfigError("arm name %r: use letters, digits, _ . + -" % name)
        bnc = os.path.abspath(bnc)
        if not (os.path.isfile(bnc) and os.access(bnc, os.X_OK)):
            raise ConfigError("arm %s: %s is not an executable file" % (name, bnc))
        fl = shlex.split(flags.get(name, ""))
        bad = [f for f in fl if f.startswith(("-fnative-place", "--backend", "-o"))
               or f in ("-I", "-L", "--build-dir")]
        if bad:
            raise ConfigError("arm %s: --arm-flags may not set %s (the driver does)"
                              % (name, " ".join(bad)))
        back = backs.get(name, bld.NATIVE)
        if back not in (bld.NATIVE, bld.LLVM):
            raise ConfigError("arm %s: backend must be native or llvm, not %r" % (name, back))
        arms.append(bld.Arm(i, name, bnc, fl, back, _sha(bnc)))
    names = {a.name for a in arms}
    for what, d in (("--arm-flags", flags), ("--arm-backend", backs)):
        extra = sorted(set(d) - names)
        if extra:
            raise ConfigError("%s names unknown arm(s): %s" % (what, ", ".join(extra)))
    if len(arms) > st.MAX_ARMS:
        raise ConfigError("at most %d arms" % st.MAX_ARMS)
    return arms


def make_items(args):
    subject = os.path.realpath(args.subject)
    if not os.path.isfile(os.path.join(subject, "scripts", "binate-paths.sh")):
        raise ConfigError("--subject %s has no scripts/binate-paths.sh" % subject)
    if args.workload == "selfcompile":
        for opt, v in (("--bench", args.bench), ("--only", args.only), ("--n", args.n)):
            if v:
                raise ConfigError("%s is for --workload bench" % opt)
        pkg = os.path.join(subject, "cmd", "bnc")
        if not os.path.isdir(pkg):
            raise ConfigError("--subject %s has no cmd/bnc" % subject)
        return [bld.Item(0, "selfcompile", "bnc", pkg)]
    if args.work_flags is not None:
        raise ConfigError("--work-flags is for --workload selfcompile")
    if not args.bench:
        raise ConfigError("--workload bench needs --bench DIR")
    root = os.path.realpath(args.bench)
    only = [n for v in args.only for n in v.split(",") if n]
    try:
        names = benchcfg.discover(root, only)
    except (OSError, ValueError) as e:
        raise ConfigError(str(e))
    if not names:
        raise ConfigError("no benchmarks under %s" % root)
    sizes = _pairs(args.n, "--n")
    extra = sorted(set(sizes) - set(names))
    if extra:
        raise ConfigError("--n names benchmark(s) not run: %s" % ", ".join(extra))
    items = []
    for i, name in enumerate(names):
        d = os.path.join(root, name)
        try:
            cfg = benchcfg.read_config(d)
        except RuntimeError as e:
            raise ConfigError(str(e))
        n = sizes.get(name, cfg["default_n"])
        if not re.match(r"^\d+$", n):
            raise ConfigError("%s: size %r is not a decimal integer" % (name, n))
        exp = os.path.join(d, "expected.txt")
        items.append(bld.Item(i, "bench", name, os.path.join(d, "binate", "cmd", name),
                              os.path.join(d, "binate"), int(n), cfg["compare"],
                              cfg["default_n"], exp if os.path.isfile(exp) else None))
    return items


class Config:
    """A validated experiment."""

    def __init__(self, args):
        self.args = args
        self.work = os.path.realpath(args.work)
        self.subject = os.path.realpath(args.subject)
        self._sources = None
        self.arms = make_arms(args)
        self.items = make_items(args)
        self.seeds = parse_seeds(args.seeds)
        if args.reps < 1 or args.jobs < 1:
            raise ConfigError("--reps and --jobs must be at least 1")
        if args.aa and len(self.arms) < 2:
            raise ConfigError("--aa needs at least two arms")
        if args.max_load is not None and args.max_load <= 0:
            raise ConfigError("--max-load must be positive")
        wf = args.work_flags if args.work_flags is not None else DEFAULT_WORK_FLAGS
        self.work_flags = shlex.split(wf) if args.workload == "selfcompile" else []

    def tmp_root(self):
        """(the directory holding the runs' TMPDIR, HOME and outputs, whether
        the driver makes and removes it): --tmpdir, else a directory named
        after the work directory under the first tmpfs mount, else WORK/tmp."""
        if self.args.tmpdir:
            return os.path.realpath(self.args.tmpdir), False
        base = runner.tmpfs_root()
        if base is None:
            return os.path.join(self.work, "tmp"), False
        tag = hashlib.sha256(self.work.encode()).hexdigest()[:10]
        return os.path.join(os.path.realpath(base), "bnplace-" + tag), True

    def timed_env(self):
        """The environment of every timed run, before the pad."""
        root = self.tmp_root()[0]
        return runner.base_env(runner.FIXED_PATH, os.path.join(root, "home"),
                               os.path.join(root, "tmp"))

    def sources(self):
        """Digests of what the builds read: SUBJECT's sources and, per
        benchmark, its binate/ tree and expected.txt (computed once)."""
        if self._sources is None:
            out = {"subject": st.source_digest(self.subject)}
            for it in self.items:
                if it.kind == "bench":
                    out["bench/" + it.name] = st.source_digest(it.root)
                    out["expected/" + it.name] = _sha(it.expected) if it.expected else None
            self._sources = out
        return dict(self._sources)

    def record(self):
        """The part of the configuration a resumed experiment must share
        (see the module doc)."""
        a = self.args
        return {"workload": a.workload, "subject": self.subject,
                "bench": os.path.realpath(a.bench) if a.bench else None,
                "work": self.work, "work_flags": self.work_flags,
                "items": [{"name": i.name, "n": i.n, "compare": i.compare} for i in self.items],
                "arms": [{"name": r.name, "bnc": r.bnc, "sha256": r.sha, "flags": r.flags,
                          "backend": r.backend} for r in self.arms],
                "seeds": self.seeds, "reps": a.reps, "mode": a.mode, "aslr": a.aslr,
                "aa": a.aa, "static_report": a.static_report,
                "timed_env": self.timed_env(),
                "stack_limit": list(resource.getrlimit(resource.RLIMIT_STACK)),
                "personality": runner.persona_bits(), "sources": self.sources()}
