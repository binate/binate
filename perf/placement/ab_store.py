"""The on-disk layout of a placement A/B experiment (ab.py's --work DIR).

  meta.json     configuration (with the timed environment, the stack size
                limit, the personality flags and a digest of the sources
                the builds read, all of which a resume must share), host
                (CPU, microcode, kernel ASLR), git HEADs (at the start and at
                each resume), compiler SHA-256s, preflight result,
                start/end/abort state
  builds.tsv    one row per build: kind (seed, seed0, noflag), arm, seed,
                placement seed, SHA-256 of the binary and of its .text, text
                size, the layout.py --expect-seed verdict, build time
  samples.tsv   one row per timed run (SAMPLE_COLS)
  store/aNN/sNNNNN[/bNN]/bin   the binary arm NN built for round seed NNNNN
                (bench item NN in bench mode); seed0 builds are s00000 and
                the no-placement-flag builds noflag, the same width
  ref/          the reference output of each workload item
  log.txt       the driver's log

Every binary path has the same length, so the timed program's argv and exec
path (both copied onto its initial stack) do not differ between arms.  The
logs are appended a row at a time and flushed to disk, so an interrupted run
loses at most the row being written; read_tsv drops such a partial last row.

Python standard library only.  The tests are in test_ab.py and test_runner.py;
nothing runs them automatically:
  python3 -m unittest discover perf/placement
"""

import hashlib
import json
import os
import platform
import subprocess
import sys

ARM_WIDTH, SEED_WIDTH, ITEM_WIDTH = 2, 5, 2
MAX_ARMS = 10 ** ARM_WIDTH
MAX_SEED = 10 ** SEED_WIDTH - 1
NOFLAG = "noflag"

SAMPLE_COLS = ("round", "seed", "rep", "pad", "aslr", "workload", "bench", "n", "arm",
               "arm_idx", "pos", "user", "sys", "wall", "maxrss", "minflt", "majflt",
               "nvcsw", "nivcsw", "steal", "load1", "out_hash", "out_ok", "cycles", "insns")
BUILD_COLS = ("kind", "arm", "arm_idx", "backend", "item", "seed", "place_seed", "mode",
              "sha256", "text_sha256", "text_size", "expect_seed", "build_s", "path", "cov")

assert len(NOFLAG) == 1 + SEED_WIDTH


def seed_label(seed):
    """The store directory of round seed `seed`, or NOFLAG for None."""
    if seed is None:
        return NOFLAG
    if not 0 <= seed <= MAX_SEED:
        raise ValueError("seed %r does not fit the store's %d digits" % (seed, SEED_WIDTH))
    return "s%0*d" % (SEED_WIDTH, seed)


def arm_dir(work, arm_idx):
    if not 0 <= arm_idx < MAX_ARMS:
        raise ValueError("arm index %r does not fit the store's %d digits"
                         % (arm_idx, ARM_WIDTH))
    return os.path.join(work, "store", "a%0*d" % (ARM_WIDTH, arm_idx))


def item_sub(kind, idx):
    """The item part of a store path: none for the self-compile, bNN for a
    benchmark."""
    if kind == "selfcompile":
        return ""
    if not 0 <= idx < 10 ** ITEM_WIDTH:
        raise ValueError("item index %r does not fit the store's %d digits"
                         % (idx, ITEM_WIDTH))
    return "b%0*d" % (ITEM_WIDTH, idx)


def build_dir(work, arm_idx, seed, sub):
    """store/aNN/<seed_label(seed)>[/bNN] under work."""
    return os.path.join(arm_dir(work, arm_idx), seed_label(seed), sub)


def bin_path(work, arm_idx, seed, sub):
    return os.path.join(build_dir(work, arm_idx, seed, sub), "bin")


# --- TSV logs ---------------------------------------------------------------------

def _cell(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, float):
        return "%.6f" % v
    s = str(v)
    if "\t" in s or "\n" in s:
        raise ValueError("TSV cell holds a tab or newline: %r" % (s,))
    return s


def read_tsv(path, cols=None):
    """Rows of a TSV log as dicts (all strings), dropping a last line that
    has no newline (a write cut short).  [] for a missing file.  With cols,
    the header must match."""
    try:
        with open(path) as fh:
            text = fh.read()
    except FileNotFoundError:
        return []
    lines = text.split("\n")
    lines.pop()  # '' after the last newline, or a partial row
    if not lines:
        return []
    header = lines[0].split("\t")
    if cols is not None and tuple(header) != tuple(cols):
        raise ValueError("%s: header %s, expected %s" % (path, header, list(cols)))
    return [dict(zip(header, ln.split("\t"))) for ln in lines[1:] if ln]


class TsvLog:
    """An append-only TSV file with a fixed header; each row is flushed and
    fsynced as it is written."""

    def __init__(self, path, cols):
        self.path, self.cols = path, tuple(cols)
        if os.path.exists(path):
            read_tsv(path, cols)
            self._trim()
        else:
            self.rewrite([])

    def _trim(self):
        # Cut a partial last row so the next append starts on a fresh line.
        with open(self.path, "rb") as fh:
            data = fh.read()
        if data and not data.endswith(b"\n"):
            with open(self.path, "wb") as fh:
                fh.write(data[:data.rfind(b"\n") + 1])

    def append(self, row):
        line = "\t".join(_cell(row.get(c)) for c in self.cols) + "\n"
        with open(self.path, "a") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())

    def rewrite(self, rows):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("\t".join(self.cols) + "\n")
            for row in rows:
                fh.write("\t".join(_cell(row.get(c)) for c in self.cols) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)


# --- metadata ---------------------------------------------------------------------

def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def read_json(path):
    with open(path) as fh:
        return json.load(fh)


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return None


def cpu_info(cpuinfo="/proc/cpuinfo"):
    """Model name, family/model/stepping and microcode of the first CPU."""
    text = _read(cpuinfo)
    out = {}
    if text:
        for line in text.split("\n\n")[0].splitlines():
            k, _, v = line.partition(":")
            k = k.strip()
            if k in ("model name", "cpu family", "model", "stepping", "microcode",
                     "vendor_id", "CPU implementer", "CPU part", "CPU variant",
                     "CPU revision"):
                out[k] = v.strip()
    elif sys.platform == "darwin":
        try:
            out["model name"] = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                text=True).stdout.strip()
        except OSError:
            pass
    return out


def host_info():
    aslr = _read("/proc/sys/kernel/randomize_va_space")
    return {"node": platform.node(), "system": platform.system(),
            "release": platform.release(), "machine": platform.machine(),
            "cpus": os.cpu_count(), "cpu": cpu_info(),
            "kernel_aslr": aslr.strip() if aslr else None,
            "python": platform.python_version()}


def git_head(path):
    """{'head', 'dirty'} of the git checkout holding path, or None; dirty
    counts untracked files too, since a new source file changes a build."""
    d = path if os.path.isdir(path) else os.path.dirname(path)
    try:
        head = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True,
                              text=True)
        if head.returncode != 0:
            return None
        st = subprocess.run(["git", "-C", d, "status", "--porcelain"], capture_output=True,
                            text=True)
    except OSError:
        return None
    return {"head": head.stdout.strip(), "dirty": bool(st.stdout.strip())}


# What bnc reads from a package directory: sources, interfaces, assembly.
SOURCE_EXTS = (".bn", ".bni", ".s")


def source_digest(root, exts=SOURCE_EXTS):
    """SHA-256 over the relative path and the contents of every file under
    root ending in one of exts, in sorted order, skipping directories whose
    name starts with '.'; None when root is not a directory.  Any package an
    import path can resolve to under a search root is covered, whatever its
    path."""
    if not os.path.isdir(root):
        return None
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.endswith(exts):
                path = os.path.join(dirpath, name)
                with open(path, "rb") as fh:
                    body = hashlib.sha256(fh.read()).digest()
                h.update(os.path.relpath(path, root).encode() + b"\0" + body)
    return h.hexdigest()


def config_diff(old, new):
    """Keys whose values differ between two experiment configurations, as
    'key' or, between two dicts, 'key.subkey'; a seed list that extends the
    old one is no difference (more rounds)."""
    out = []
    for k in sorted(set(old) | set(new)):
        a, b = old.get(k), new.get(k)
        if k == "seeds" and isinstance(a, list) and isinstance(b, list) and b[:len(a)] == a:
            continue
        if a == b:
            continue
        if isinstance(a, dict) and isinstance(b, dict):
            out.extend("%s.%s" % (k, sk) for sk in sorted(set(a) | set(b))
                       if a.get(sk) != b.get(sk))
        else:
            out.append(k)
    return out
