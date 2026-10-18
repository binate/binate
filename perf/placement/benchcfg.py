"""The benchmarks repository's per-benchmark settings and output check.

A benchmark lives in <bench>/<name>/: config.sh (shell assignments of
DEFAULT_N, SMALL_N and COMPARE), expected.txt (its output at DEFAULT_N) and
binate/cmd/<name> (the Binate program, built with binate/ as an extra package
search root).  read_config sources config.sh with sh, as the repository's own
scripts do, so whatever shell logic it holds is honoured; outputs_agree
reproduces their scripts/lib.sh outputs_agree:

  exact, bytes  byte-identical;
  anything else (float, the default)  the same number of lines, each pair of
                lines within 1e-8 as numbers.

A line is read as a number the way awk does with C's strtod (mawk, the usual
Linux awk): its longest leading number, which may be decimal, hexadecimal
(0x10, 0x1.8p3), inf, infinity or nan (any case, signed), and 0 when it has
none.  So a float benchmark that miscompiles into inf or nan is caught,
where reading only decimal digits would take 'inf' as 0 and match a reference
of 0.  Two values agree when they are within 1e-8, both the same infinity, or
both NaN; NaN never agrees with a number.  lib.sh under mawk accepts NaN
against any number (mawk takes a comparison with NaN as true), which an
output check must not do; that is the one place the two differ.

Python standard library only.  The tests are in test_benchcfg.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import math
import os
import re
import subprocess

FLOAT_TOL = 1e-8
_SHOW = ('DEFAULT_N=""; SMALL_N=""; COMPARE=float; . ./config.sh || exit 1; '
         'printf "%s\\n%s\\n%s\\n" "$DEFAULT_N" "$SMALL_N" "$COMPARE"')
_NUM_RE = re.compile(
    rb"^[ \t\n\r\f\v]*([-+]?)(?:"
    rb"(0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][-+]?\d+)?)"
    rb"|((?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)"
    rb"|([iI][nN][fF](?:[iI][nN][iI][tT][yY])?)"
    rb"|([nN][aA][nN])(?:\([0-9A-Za-z_]*\))?)")


def read_config(bench_dir, sh="/bin/sh"):
    """{'default_n', 'small_n', 'compare'} from bench_dir/config.sh, sourced
    by sh (with run.sh's defaults: no sizes, COMPARE=float).  Raises
    RuntimeError when it cannot be sourced."""
    p = subprocess.run([sh, "-c", _SHOW], cwd=bench_dir, capture_output=True, text=True)
    lines = p.stdout.split("\n")
    if p.returncode != 0 or len(lines) < 3:
        raise RuntimeError("%s/config.sh: cannot be sourced: %s"
                           % (bench_dir, p.stderr.strip()))
    return {"default_n": lines[0], "small_n": lines[1], "compare": lines[2] or "float"}


def discover(bench_root, only=()):
    """Sorted names of the benchmarks under bench_root (a directory with
    config.sh and binate/cmd/<name>), limited to `only` when given.  Raises
    ValueError for a name in `only` that is not such a benchmark."""
    names = sorted(n for n in os.listdir(bench_root)
                   if os.path.isfile(os.path.join(bench_root, n, "config.sh"))
                   and os.path.isdir(os.path.join(bench_root, n, "binate", "cmd", n)))
    if only:
        bad = [n for n in only if n not in names]
        if bad:
            raise ValueError("not a benchmark under %s: %s" % (bench_root, ", ".join(bad)))
        names = [n for n in names if n in set(only)]
    return names


def _lines(data):
    if not data:
        return []
    parts = data.split(b"\n")
    if parts[-1] == b"":
        parts.pop()
    return parts


def awk_number(line):
    """The number a strtod-based awk reads from a line used as a number (see
    the module doc)."""
    m = _NUM_RE.match(line)
    if not m:
        return 0.0
    sign, hexa, dec, inf, nan = m.groups()
    neg = sign == b"-"
    if nan:
        return float("nan")
    if inf:
        return float("-inf") if neg else float("inf")
    if dec:
        v = float(dec)
    else:
        try:
            v = float.fromhex(hexa.decode())
        except OverflowError:
            v = float("inf")
    return -v if neg else v


def values_agree(x, y):
    """Within FLOAT_TOL, the same infinity, or both NaN."""
    if math.isnan(x) or math.isnan(y):
        return math.isnan(x) and math.isnan(y)
    return x == y or abs(x - y) <= FLOAT_TOL


def outputs_agree(a, b, compare):
    """Whether two outputs (bytes) agree under COMPARE (see the module doc)."""
    if compare in ("bytes", "exact"):
        return a == b
    la, lb = _lines(a), _lines(b)
    if len(la) != len(lb):
        return False
    return all(values_agree(awk_number(x), awk_number(y)) for x, y in zip(la, lb))
