"""Timed child processes for placement A/B measurements.

spawn() runs one program and returns a Sample: the child's user and system
CPU time, wall time, peak RSS, page faults and context switches (os.wait4),
the SHA-256 of its output, the host's stolen CPU time during the run (the
steal column of /proc/stat, averaged over CPUs) and the 1-minute load average
when it started.  On Linux a child's maxrss never reads below this process's
peak RSS so far (its high-water mark, not its current RSS): the child starts
as a copy of (or, with vfork, inside) this process's address space, and exec
carries that space's high-water mark into the child's.  So a transient
allocation in the driver raises every later child's maxrss, and the floor
differs between a fresh and a resumed experiment; only a peak above the
driver's own is the program's.

A child killed by SIGINT or SIGTERM makes spawn raise KeyboardInterrupt
instead of returning the run: a terminal's Ctrl-C (or a signal to the process
group) reaches the timed program as well as the driver, and such a run was
interrupted, not wrong.

What a timed program sees is fixed so that only the placement under test
moves its addresses:

- the environment is a fixed, scrubbed set (PATH=FIXED_PATH, LC_ALL=C, HOME,
  a TMPDIR on tmpfs) plus BN_PLACE_PAD='x' * pad, so the pad alone sets how
  far down the initial stack starts, whatever environment the driver was
  started from (the kernel copies the environment onto the stack and keeps
  the stack pointer 16-byte aligned, so each 16 bytes of pad move it by 16);
- with ASLR off (set_aslr: personality(2) with ADDR_NO_RANDOMIZE, inherited by
  every child) the stack, heap and mmap bases do not move between runs.
  preflight() checks both properties before any timing: a child's startstack
  (/proc/self/stat) must be identical across two runs with the same pad and
  move by exactly 16 bytes between pads L and L + 16.

macOS has no personality(2): the runs then keep ASLR on (logged), preflight
has no /proc to read, and when /usr/bin/time is present every run goes through
`/usr/bin/time -l`, whose cycle and retired-instruction counts land in the
Sample (None elsewhere).

Python standard library only.  The tests are in test_runner.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import ctypes
import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections import namedtuple

ADDR_NO_RANDOMIZE = 0x0040000
QUERY_PERSONA = 0xFFFFFFFF
PAD_VAR = "BN_PLACE_PAD"
STACK_STEP = 16
TIME_L = "/usr/bin/time"
# The PATH of every timed run: fixed, so that the invoking shell's PATH does
# not move the initial stack.  It holds the C toolchain bnc may call (clang).
FIXED_PATH = "/usr/bin:/bin"
INTERRUPT_CODES = (-signal.SIGINT, -signal.SIGTERM)

FIELDS = ("user", "sys", "wall", "maxrss", "minflt", "majflt", "nvcsw", "nivcsw",
          "steal", "load1", "out_hash", "rc", "cycles", "insns")


class Sample(namedtuple("Sample", FIELDS)):
    """One run.  user/sys/wall in seconds, maxrss in KiB, steal in seconds of
    stolen CPU time per CPU (None without /proc/stat), out_hash the
    SHA-256 hex of the hashed output ('' when it is missing), rc the exit code
    (negative for a signal), cycles/insns from `/usr/bin/time -l` (None when
    unavailable)."""
    __slots__ = ()


class AslrError(RuntimeError):
    """ASLR could not be put in the state asked for."""


class PreflightError(RuntimeError):
    """The stack does not start where the pad says it should."""


def _log(msg):
    print(msg, file=sys.stderr)


# --- environment ----------------------------------------------------------------

def mount_types(mounts="/proc/mounts"):
    """{mount point: filesystem type}, empty when the table is unreadable."""
    out = {}
    try:
        with open(mounts) as fh:
            for line in fh:
                f = line.split()
                if len(f) >= 3:
                    out[f[1].replace("\\040", " ")] = f[2]
    except OSError:
        pass
    return out


def fs_type(path, mounts="/proc/mounts"):
    """Filesystem type of the mount holding path (symlinks resolved), or
    None if unknown."""
    table = mount_types(mounts)
    path = os.path.realpath(path)
    best = None
    for mp in table:
        if path == mp or path.startswith(mp.rstrip("/") + "/"):
            if best is None or len(mp) > len(best):
                best = mp
    return table.get(best) if best else None


def tmpfs_root(mounts="/proc/mounts", candidates=("/dev/shm", "/run/shm", "/tmp")):
    """The first candidate directory on tmpfs, or None."""
    for c in candidates:
        if os.path.isdir(c) and fs_type(c, mounts) == "tmpfs":
            return c
    return None


def base_env(path, home, tmpdir):
    """The scrubbed environment every timed run gets, before the pad."""
    return {"PATH": path, "LC_ALL": "C", "HOME": home, "TMPDIR": tmpdir}


def run_env(base, pad_len):
    """base plus BN_PLACE_PAD='x' * pad_len (present even when empty)."""
    if not isinstance(pad_len, int) or pad_len < 0:
        raise ValueError("pad length must be a non-negative int, not %r" % (pad_len,))
    env = dict(base)
    env.pop(PAD_VAR, None)
    env[PAD_VAR] = "x" * pad_len
    return env


# --- ASLR -----------------------------------------------------------------------

_PERSONALITY = []


def load_personality(platform=None):
    """libc personality(2) as a callable, or None off Linux."""
    if not (platform or sys.platform).startswith("linux"):
        return None
    if not _PERSONALITY:
        libc = ctypes.CDLL(None, use_errno=True)
        fn = libc.personality
        fn.argtypes = [ctypes.c_ulong]
        fn.restype = ctypes.c_int
        _PERSONALITY.append(fn)
    return _PERSONALITY[0]


def _persona(persona):
    cur = persona(QUERY_PERSONA)
    if cur == -1:
        raise AslrError("personality(2) query failed: %s" % os.strerror(ctypes.get_errno()))
    return cur


def persona_bits(persona="auto"):
    """This process's personality(2) flags other than ADDR_NO_RANDOMIZE
    (they are inherited too, and some move the address-space layout), or
    None without personality(2)."""
    if persona == "auto":
        persona = load_personality()
    if persona is None:
        return None
    return _persona(persona) & ~ADDR_NO_RANDOMIZE


def aslr_state(persona):
    """'off' if this process (and so every child it starts) runs with
    ADDR_NO_RANDOMIZE, else 'on'; 'on' when persona is None."""
    if persona is None:
        return "on"
    return "off" if _persona(persona) & ADDR_NO_RANDOMIZE else "on"


def set_aslr(mode, persona="auto", log=_log):
    """Put this process, and so every child started from now on, in ASLR
    state mode ('off' or 'on') and return the state reached.  On Linux a
    failure raises AslrError; with no personality(2) (macOS) the state stays
    'on' and that is logged."""
    if mode not in ("off", "on"):
        raise ValueError("ASLR mode must be off or on, not %r" % (mode,))
    if persona == "auto":
        persona = load_personality()
    if persona is None:
        if mode == "off":
            log("runner: this system has no personality(2); timed runs keep ASLR on")
        return "on"
    cur = _persona(persona)
    want = cur | ADDR_NO_RANDOMIZE if mode == "off" else cur & ~ADDR_NO_RANDOMIZE
    if want != cur and persona(want) == -1:
        raise AslrError("personality(%#x) failed: %s"
                        % (want, os.strerror(ctypes.get_errno())))
    got = aslr_state(persona)
    if got != mode:
        raise AslrError("personality(2) did not take: ASLR is %s, wanted %s" % (got, mode))
    return got


# --- one run --------------------------------------------------------------------

DROP_CACHES = "/proc/sys/vm/drop_caches"


def drop_page_cache(path=DROP_CACHES):
    """Write dirty pages back and drop the clean page cache (Linux, root), so
    every binary is read back from disk when it first runs.  A binary's
    page-cache pages then come in the order the timed runs first use them
    rather than the order the builds wrote them.  OSError when not allowed."""
    os.sync()
    with open(path, "w") as fh:
        fh.write("3\n")


def read_steal(path="/proc/stat"):
    """Total stolen CPU time in clock ticks (the 'cpu' line's 8th value), or
    None if unavailable."""
    try:
        with open(path) as fh:
            f = fh.readline().split()
        return int(f[8]) if f and f[0] == "cpu" and len(f) > 8 else None
    except (OSError, ValueError):
        return None


def sha256_file(path):
    """SHA-256 hex of the file at path, or '' if it cannot be read."""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


TIME_L_RE = {"insns": re.compile(r"^\s*(\d+)\s+instructions retired\s*$", re.M),
             "cycles": re.compile(r"^\s*(\d+)\s+cycles elapsed\s*$", re.M)}


def parse_time_l(text):
    """(cycles, insns) from `/usr/bin/time -l` output; None for a count it
    does not print (older macOS)."""
    got = {}
    for k, rx in TIME_L_RE.items():
        m = rx.findall(text)
        got[k] = int(m[-1]) if m else None
    return got["cycles"], got["insns"]


def default_time_l(platform=None, exists=os.path.exists):
    """/usr/bin/time on macOS when it exists, else None."""
    return TIME_L if (platform or sys.platform) == "darwin" and exists(TIME_L) else None


def spawn(argv, pad_len, cwd, out_path, aslr, env=None, hash_path=None, err_path=None,
          persona="auto", time_l="auto", platform=None):
    """Run argv once and return its Sample.  stdout goes to out_path, stderr to
    err_path (default out_path + '.err'), stdin is /dev/null; out_hash hashes
    hash_path (default out_path) after the run.  env is the scrubbed base
    environment (base_env; default: FIXED_PATH, HOME=/ and TMPDIR=/tmp) and
    gets the pad added.  aslr is the state the run is recorded under: on
    Linux it must match this process's personality, which children
    inherit, else AslrError.  KeyboardInterrupt when the child was killed by
    SIGINT or SIGTERM (see the module doc)."""
    platform = platform or sys.platform
    if persona == "auto":
        persona = load_personality(platform)
    if persona is not None and aslr_state(persona) != aslr:
        raise AslrError("run recorded as ASLR %s but the process has it %s"
                        % (aslr, aslr_state(persona)))
    if time_l == "auto":
        time_l = default_time_l(platform)
    if env is None:
        env = base_env(FIXED_PATH, "/", "/tmp")
    full_env = run_env(env, pad_len)
    cmd = ([time_l, "-l"] if time_l else []) + list(argv)
    err_path = err_path or out_path + ".err"
    load1 = os.getloadavg()[0]
    steal0 = read_steal()
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        t0 = time.perf_counter()
        proc = subprocess.Popen(cmd, cwd=cwd, env=full_env, stdin=subprocess.DEVNULL,
                                stdout=out, stderr=err, close_fds=True)
        try:
            _, status, ru = os.wait4(proc.pid, 0)
        except BaseException:
            # The child may be dead already (a Ctrl-C reaches the whole
            # process group) and even reaped, by os.wait4 or by the poll()
            # inside kill(); wait() then returns at once where waitpid would
            # fail with ECHILD and hide the interrupt.
            proc.kill()
            proc.wait()
            raise
        wall = time.perf_counter() - t0
    proc.returncode = os.waitstatus_to_exitcode(status)
    if proc.returncode in INTERRUPT_CODES:
        raise KeyboardInterrupt("timed run killed by signal %d" % -proc.returncode)
    steal1 = read_steal()
    steal = None
    if steal0 is not None and steal1 is not None:
        steal = (steal1 - steal0) / os.sysconf("SC_CLK_TCK") / (os.cpu_count() or 1)
    cycles = insns = None
    if time_l:
        with open(err_path, errors="replace") as fh:
            cycles, insns = parse_time_l(fh.read())
    maxrss = ru.ru_maxrss // 1024 if platform == "darwin" else ru.ru_maxrss
    return Sample(user=ru.ru_utime, sys=ru.ru_stime, wall=wall, maxrss=maxrss,
                  minflt=ru.ru_minflt, majflt=ru.ru_majflt, nvcsw=ru.ru_nvcsw,
                  nivcsw=ru.ru_nivcsw, steal=steal, load1=load1,
                  out_hash=sha256_file(hash_path or out_path), rc=proc.returncode,
                  cycles=cycles, insns=insns)


# --- preflight ------------------------------------------------------------------

def parse_startstack(stat_text):
    """Field 28 (startstack) of a /proc/<pid>/stat line; the command name in
    field 2 may hold spaces and parentheses, so fields count from the last
    ')'."""
    rest = stat_text[stat_text.rindex(")") + 1:].split()
    return int(rest[28 - 3])


def startstack(env, pad_len, cwd, aslr, spawn_fn=spawn):
    """The startstack of a child run like a timed run with pad pad_len."""
    cat = shutil.which("cat", path=env.get("PATH")) or "/bin/cat"
    out = os.path.join(cwd, "preflight.stat")
    s = spawn_fn([cat, "/proc/self/stat"], pad_len, cwd, out, aslr, env=env)
    with open(out) as fh:
        text = fh.read()
    if s.rc != 0:
        raise PreflightError("%s /proc/self/stat exited %d" % (cat, s.rc))
    return parse_startstack(text)


def preflight(env, cwd, aslr, pad=0, spawn_fn=spawn, have_proc=None, log=_log):
    """Check that the pad alone moves the stack: with ASLR off a child's
    startstack must be the same in two runs with pad `pad` and exactly
    STACK_STEP bytes lower with pad + STACK_STEP.  Returns a record for the
    experiment's metadata; raises PreflightError.  Skipped (and logged) with
    ASLR on or without /proc."""
    if have_proc is None:
        have_proc = os.path.exists("/proc/self/stat")
    if not have_proc:
        log("runner: no /proc/self/stat; stack preflight skipped")
        return {"checked": False, "why": "no /proc"}
    if aslr != "off":
        log("runner: ASLR is on; stack preflight skipped (the stack moves on every exec)")
        return {"checked": False, "why": "ASLR on"}
    a = startstack(env, pad, cwd, aslr, spawn_fn)
    b = startstack(env, pad, cwd, aslr, spawn_fn)
    c = startstack(env, pad + STACK_STEP, cwd, aslr, spawn_fn)
    rec = {"checked": True, "pad": pad, "startstack": [a, b, c]}
    if a != b:
        raise PreflightError("startstack moved between two runs with the same pad "
                             "(%#x, %#x): ASLR is not off" % (a, b))
    if a - c != STACK_STEP:
        raise PreflightError("startstack moved by %d bytes, not %d, for %d more bytes of "
                             "pad (%#x -> %#x)" % (a - c, STACK_STEP, STACK_STEP, a, c))
    return rec
