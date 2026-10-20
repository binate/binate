"""Stand-ins for the tests of ab.py: a fake bnc, a fake layout.py, a fake
Binate tree and a fake benchmarks tree.

The fake bnc takes bnc's command line and writes, at -o, a shell script that
behaves like the program it was asked to build: a benchmark prints
'Result(N) = 42' (or float lines), the self-compile copies a fixed text to its
-o.  The script's '# TEXT <payload>' line stands for its .text: the payload
is what the placement seed and the compiler's tag would change in a real
build, so fake_text_facts (patched in for binfile.text_facts) gives each
build the identity a real .text would have.  Behaviour switches, fixed when
the fake is written (the builds run in a scrubbed environment):

  tag            distinguishes compilers (two tags = an A/B pair)
  ignore_seed    the placement switches change nothing
  seed0_differs  -fnative-place-seed=0 changes the output
  bad_layout     every seeded build fails the fake layout.py
  bad_seed=S     the program built with seed S prints a wrong result
  sigint_seed=S  the program built with seed S kills itself with SIGINT, as a
                 Ctrl-C to the process group would
  sigint_build=S building with seed S dies of SIGINT
  fail_seed=S    building with seed S fails
  nondet         the self-compile writes a different output every run
  float=NAME     benchmark NAME prints float lines, with seed-dependent
                 noise below the 1e-8 tolerance
  probe_misses   -fnative-place-probe matches no function: the probe
                 switches change nothing, and the fake layout.py's --probe
                 finds no such function (exit 3)

The fake layout.py checks a --probe SYM --probe-phase P against the probe the
fake bnc recorded in the payload, and exits 1 when they differ.

Every invocation is logged, one line, to <fake>.calls.  FlowBase is the base
of the tests that run ab.py end to end with these stand-ins.

Python standard library only; nothing runs the tests automatically:
  python3 -m unittest discover perf/placement
"""

import contextlib
import hashlib
import io
import json
import os
import signal
import sys
import tempfile
import unittest
from unittest import mock

import ab
import ab_build as bld
import ab_store as st
import binfile

FAKE_BNC = r'''#!%(python)s
import os, sys
B = %(behavior)r
with open(%(calls)r, "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
args = sys.argv[1:]
seed = mode = out = backend = bdir = probe = phase = None
i = 0
while i < len(args):
    a = args[i]
    if a.startswith("-fnative-place-seed="):
        seed = int(a.split("=", 1)[1])
    elif a.startswith("-fnative-place-mode="):
        mode = a.split("=", 1)[1]
    elif a.startswith("-fnative-place-probe="):
        probe = a.split("=", 1)[1]
    elif a.startswith("-fnative-place-probe-phase="):
        phase = int(a.split("=", 1)[1])
    elif a in ("-o", "--backend", "--build-dir", "-I", "-L", "--cflag"):
        val = args[i + 1]
        if a == "-o":
            out = val
        elif a == "--backend":
            backend = val
        elif a == "--build-dir":
            bdir = val
        i += 1
    i += 1
pkg = args[-1]
if bdir is not None and not os.path.isdir(bdir):
    sys.exit("build dir missing")
if seed is not None and seed == B.get("fail_seed"):
    sys.exit("fake build failure")
if seed is not None and seed == B.get("sigint_build"):
    import signal
    os.kill(os.getpid(), signal.SIGINT)
eff = seed if seed and not B.get("ignore_seed") else 0
if seed == 0 and B.get("seed0_differs"):
    eff = "zero"
payload = "%%s:%%s:%%s:%%s" %% (B.get("tag", ""), backend, eff, mode if seed else "")
if B.get("bad_layout") and seed:
    payload += ":badlayout"
if probe is not None and not B.get("probe_misses"):
    payload += ":probe=%%s@%%d" %% (probe, phase)
if pkg.rstrip("/").endswith("cmd/bnc"):
    body = ('o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done\n'
            + ('echo "compiled $$" > "$o"\n' if B.get("nondet") else 'echo compiled > "$o"\n'))
else:
    bad = seed is not None and seed == B.get("bad_seed")
    if seed is not None and seed == B.get("sigint_seed"):
        body = 'kill -INT $$\n'
    elif os.path.basename(pkg.rstrip("/")) == B.get("float"):
        # Seed-dependent noise below the 1e-8 tolerance, or a wrong value.
        val = "0.2" if bad else "0.12345678%%d" %% (len(payload) %% 10)
        body = 'echo %%s\necho -0.5\n' %% val
    else:
        body = 'echo "Result($1) = %%s"\n' %% ("99" if bad else "42")
with open(out, "w") as fh:
    fh.write("#!/bin/sh\n# TEXT %%s\n%%s" %% (payload, body))
os.chmod(out, 0o755)
'''

FAKE_LAYOUT = r'''#!%(python)s
import json, sys
path, seed = sys.argv[1], int(sys.argv[3])
with open(path) as fh:
    payload = [l for l in fh if l.startswith("# TEXT ")][0][7:].strip()
if "--probe" in sys.argv:
    i = sys.argv.index("--probe")
    want = "%%s@%%s" %% (sys.argv[i + 1], sys.argv[sys.argv.index("--probe-phase") + 1])
    if ":probe=" not in payload:
        print("fake layout: no function has the probe symbol", file=sys.stderr)
        sys.exit(3)
    if not payload.endswith(":probe=" + want):
        sys.exit(1)
if "--json" in sys.argv:
    loops = [{"innermost": True, "windows": 3 + seed %% 2, "windows_min": 3,
              "lines": 2, "lines_min": 2, "jcc": seed %% 3}]
    print(json.dumps({"summary": {"text_bytes": 1000 + seed, "bytes": {"fill": seed * 16,
                      "pad": 4}, "erratum": {"hits": seed %% 5, "windows": 1},
                      "dense_windows": {"count": 0}}, "loops": loops}))
else:
    print("fake layout of", path)
sys.exit(1 if "badlayout" in payload else 0)
'''


def _write_exe(path, text):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, 0o755)
    return path


def fake_bnc(d, name="bnc", **behavior):
    """A fake compiler at d/name; returns its path."""
    path = os.path.join(d, name)
    return _write_exe(path, FAKE_BNC % {"python": sys.executable, "behavior": behavior,
                                        "calls": path + ".calls"})


def calls(bnc):
    """The fake compiler's invocations so far."""
    try:
        with open(bnc + ".calls") as fh:
            return fh.read().splitlines()
    except FileNotFoundError:
        return []


def fake_layout(d):
    return _write_exe(os.path.join(d, "layout.py"), FAKE_LAYOUT % {"python": sys.executable})


def fake_text_facts(path):
    with open(path) as fh:
        payload = [ln for ln in fh if ln.startswith("# TEXT ")][0][7:].strip()
    return {"text_sha256": hashlib.sha256(payload.encode()).hexdigest(),
            "text_size": 1000 + len(payload)}


def subject_tree(d):
    """A Binate tree with a binate-paths.sh and a cmd/bnc directory."""
    root = os.path.join(d, "subject")
    os.makedirs(os.path.join(root, "scripts"))
    os.makedirs(os.path.join(root, "cmd", "bnc"))
    _write_exe(os.path.join(root, "scripts", "binate-paths.sh"),
               '#!/bin/sh\nsel="$1"; shift\necho "${sel#--}:$*"\n')
    return root


def bench_tree(d, benches=None):
    """A benchmarks bench/ directory: {name: (compare, default_n, expected
    or None)}."""
    root = os.path.join(d, "bench")
    benches = benches or {"foo": ("exact", "7", "Result(7) = 42\n")}
    for name, (compare, n, expected) in benches.items():
        os.makedirs(os.path.join(root, name, "binate", "cmd", name))
        with open(os.path.join(root, name, "config.sh"), "w") as fh:
            fh.write("DEFAULT_N=%s\nSMALL_N=3\nCOMPARE=%s\n" % (n, compare))
        if expected is not None:
            with open(os.path.join(root, name, "expected.txt"), "w") as fh:
                fh.write(expected)
    return root


def read_meta(work):
    with open(os.path.join(work, "meta.json")) as fh:
        return json.load(fh)


def default_sigint(test):
    """Give the test (a TestCase) the default SIGINT handling for its
    duration.  A process started as a non-interactive shell's background job
    starts with SIGINT ignored, and its children inherit that, so a program
    that signals itself with SIGINT would not die of it and the tests of how
    a Ctrl-C is handled would fail for that reason alone."""
    if signal.getsignal(signal.SIGINT) == signal.SIG_IGN:
        signal.signal(signal.SIGINT, signal.default_int_handler)
        test.addCleanup(signal.signal, signal.SIGINT, signal.SIG_IGN)


class FlowBase(unittest.TestCase):
    """A fake Binate tree, benchmarks (foo: exact, with expected.txt; flo:
    float) and layout.py, and run_ab to run ab.py on them with ASLR left as
    it is (--aslr on), so the test process's personality is not changed."""

    def setUp(self):
        default_sigint(self)
        self.tmp = tempfile.TemporaryDirectory()
        d = self.d = os.path.realpath(self.tmp.name)
        self.subject = subject_tree(d)
        self.bench = bench_tree(d, {"foo": ("exact", "7", "Result(7) = 42\n"),
                                    "flo": ("float", "5", None)})
        self.work = os.path.join(d, "work")
        self.tmpdir = os.path.join(d, "tmpfs")
        layout = fake_layout(d)
        for p in (mock.patch.object(binfile, "text_facts", fake_text_facts),
                  mock.patch.object(bld, "LAYOUT_PY", layout)):
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def bnc(self, name, **behavior):
        return fake_bnc(self.d, name, **behavior)

    def run_ab(self, arms, *extra, workload="bench", seeds="1-3", tmpdir=None,
               allow_short=True, drop="off"):
        # The fake programs run for milliseconds, far under MIN_RUN_CPU.
        argv = ["run", "--work", self.work, "--seeds", seeds, "--workload", workload,
                "--subject", self.subject, "--aslr", "on", "--tmpdir", tmpdir or self.tmpdir,
                "--jobs", "2", "--drop-caches", drop]
        if allow_short:
            argv.append("--allow-short-runs")
        if workload == "bench":
            argv += ["--bench", self.bench]
        for name, path in arms:
            argv += ["--arm", "%s=%s" % (name, path)]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = ab.main(argv + list(extra))
        self.stderr = err.getvalue()
        return status

    def samples(self):
        return st.read_tsv(os.path.join(self.work, "samples.tsv"), st.SAMPLE_COLS)

    def builds(self):
        return st.read_tsv(os.path.join(self.work, "builds.tsv"), st.BUILD_COLS)

    def meta(self):
        return read_meta(self.work)
