"""Tests for benchcfg.py: config.sh reading, benchmark discovery and the
output comparison, which is cross-checked against the benchmarks repository's
own scripts/lib.sh outputs_agree when that checkout sits next to this one
(BENCH_LIB_SH names it explicitly).

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import math
import os
import shutil
import subprocess
import tempfile
import unittest

import benchcfg

HERE = os.path.dirname(os.path.abspath(__file__))
LIB_SH = os.environ.get("BENCH_LIB_SH") or os.path.normpath(
    os.path.join(HERE, "..", "..", "..", "benchmarks", "scripts", "lib.sh"))

CASES = [
    ("exact", b"Pfannkuchen(7) = 16\n", b"Pfannkuchen(7) = 16\n", True),
    ("exact", b"a\n", b"a", False),
    ("bytes", b"\x00\x01", b"\x00\x01", True),
    ("float", b"-0.169075164\n-0.169083134\n", b"-0.169075164\n-0.169083134\n", True),
    ("float", b"-0.169075164\n", b"-0.1690751645\n", True),
    ("float", b"-0.169075164\n", b"-0.16907518\n", False),
    ("float", b"1.0\n2.0\n", b"1.0\n", False),
    ("float", b"1.0\n", b"1.0", True),
    ("float", b"x = 3\n", b"y = 4\n", True),
    ("float", b"3 apples\n", b"3.0 pears\n", True),
    ("float", b"  2.5e-3\n", b"0.0025\n", True),
    ("float", b"", b"", True),
    ("float", b"", b"0\n", False),
    ("float", b"1e300\n", b"-1e300\n", False),
]

# Lines a strtod-based awk (mawk) reads as hexadecimal, infinite or NaN
# numbers; cross-checked against lib.sh only where the host awk does so.
STRTOD_CASES = [
    ("float", b"inf\n", b"-inf\n", False),
    ("float", b"inf\n", b"0.0\n", False),
    ("float", b"-INF\n", b"0\n", False),
    ("float", b"inf\n", b"Infinity\n", True),
    ("float", b"1e400\n", b"inf\n", True),
    ("float", b"0x10\n", b"16\n", True),
    ("float", b"0x1.8p1 x\n", b"3\n", True),
    ("float", b"nan\n", b"NaN\n", True),
]

# NaN against a number: lib.sh under mawk accepts these (mawk takes a
# comparison with NaN as true); an output check must not.
NAN_CASES = [
    ("float", b"nan\n", b"0.5\n", False),
    ("float", b"-nan(1)\n", b"inf\n", False),
]


def awk_is_strtod():
    p = subprocess.run(["awk", '{ s = s ($0 + 0) " " } END { print s }'],
                       input="inf\n0x10\n", capture_output=True, text=True)
    return p.stdout.split() == ["inf", "16"]


class ConfigTest(unittest.TestCase):
    def test_read_config_sources_shell(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "config.sh"), "w") as fh:
                fh.write("# comment\nBASE=5\nDEFAULT_N=$((BASE * 2))\nSMALL_N=3  # small\n"
                         "COMPARE=exact\n")
            self.assertEqual(benchcfg.read_config(d),
                             {"default_n": "10", "small_n": "3", "compare": "exact"})

    def test_defaults_and_failure(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "config.sh"), "w") as fh:
                fh.write("DEFAULT_N=7\n")
            self.assertEqual(benchcfg.read_config(d)["compare"], "float")
            self.assertEqual(benchcfg.read_config(d)["small_n"], "")
            os.remove(os.path.join(d, "config.sh"))
            with self.assertRaises(RuntimeError):
                benchcfg.read_config(d)

    def test_discover(self):
        with tempfile.TemporaryDirectory() as d:
            for name, ok in (("b", True), ("a", True), ("nocfg", False), ("nocmd", None)):
                os.makedirs(os.path.join(d, name))
                if ok is not False:
                    open(os.path.join(d, name, "config.sh"), "w").close()
                if ok:
                    os.makedirs(os.path.join(d, name, "binate", "cmd", name))
            self.assertEqual(benchcfg.discover(d), ["a", "b"])
            self.assertEqual(benchcfg.discover(d, ["b"]), ["b"])
            with self.assertRaises(ValueError):
                benchcfg.discover(d, ["nocmd"])


class OutputsAgreeTest(unittest.TestCase):
    def test_cases(self):
        for compare, a, b, want in CASES + STRTOD_CASES + NAN_CASES:
            with self.subTest(compare=compare, a=a, b=b):
                self.assertEqual(benchcfg.outputs_agree(a, b, compare), want)
                self.assertEqual(benchcfg.outputs_agree(b, a, compare), want)

    def test_awk_number(self):
        self.assertEqual(benchcfg.awk_number(b"  -1.5e2xyz"), -150.0)
        self.assertEqual(benchcfg.awk_number(b".5"), 0.5)
        self.assertEqual(benchcfg.awk_number(b"abc 3"), 0.0)
        for line, want in ((b"inf", math.inf), (b" -Infinity!", -math.inf), (b"0x10", 16.0),
                           (b"-0x.8p1", -1.0), (b"0x", 0.0), (b"0xg", 0.0), (b"in", 0.0),
                           (b"1e", 1.0), (b"1e400", math.inf), (b"0x1p99999", math.inf)):
            self.assertEqual(benchcfg.awk_number(line), want, line)
        for line in (b"nan", b"-NaN", b"nan(12)x", b"nan("):
            self.assertTrue(math.isnan(benchcfg.awk_number(line)), line)

    @unittest.skipUnless(os.path.isfile(LIB_SH), "benchmarks scripts/lib.sh not found")
    @unittest.skipUnless(shutil.which("awk"), "awk not found")
    def test_matches_lib_sh(self):
        with tempfile.TemporaryDirectory() as d:
            pa, pb = os.path.join(d, "a"), os.path.join(d, "b")
            cases = CASES + (STRTOD_CASES if awk_is_strtod() else [])
            for compare, a, b, want in cases:
                with open(pa, "wb") as fh:
                    fh.write(a)
                with open(pb, "wb") as fh:
                    fh.write(b)
                for x, y, bx, by in ((pa, pb, a, b), (pb, pa, b, a)):
                    rc = subprocess.run(["sh", "-c", '. "$1"; COMPARE="$2"; outputs_agree "$3" '
                                         '"$4"', "sh", LIB_SH, compare, x, y]).returncode
                    with self.subTest(compare=compare, a=bx, b=by):
                        self.assertEqual(rc == 0, benchcfg.outputs_agree(bx, by, compare))


if __name__ == "__main__":
    unittest.main()
