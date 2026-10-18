"""Tests of layout.py on real objdump output, so a drift between the synthetic
fixtures of layout_testutil.py and what the disassemblers actually print shows
up here.

testdata/fraginlist-<arch>-<syntax>.{sym,hdr,dis} are excerpts of fannkuch-redux
built by bnc with --backend native -O2 -fnative-place-seed=7 (phase mode) for
x86_64-linux, aarch64-linux and arm32-linux, and for aarch64 Mach-O linked by
ld64.lld without -dead_strip.  Each holds two functions: insertPkgEntries and
the one after it, fragInList (a runtime list walk with one loop).

  .sym  `objdump -t BIN`, keeping the lines whose address lies from the start of
        insertPkgEntries through the start of the function after fragInList,
        so fragInList's extent ends where it does in the whole binary;
  .hdr  `objdump -h BIN`;
  .dis  `objdump -d --start-address=A --stop-address=B BIN` over that range
        (llvm-objdump --macho ignores the address range, so the Mach-O excerpt
        was cut from the whole disassembly by address instead).

GNU objdump made the x86_64-gnu files, llvm-objdump 18 the others, and the
binary path was shortened to its file name.  The numbers pinned below are the
ones the whole binaries give.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import os
import unittest

import layout

HERE = os.path.dirname(os.path.abspath(__file__))
PREV = "bn_F3_3_pkg8_builtins2_rt1_16_insertPkgEntries"
FUNC = "bn_F3_3_pkg8_builtins2_rt1_10_fragInList"


def load(name, arch, fmt):
    def lines(ext):
        path = os.path.join(HERE, "testdata", "fraginlist-%s.%s" % (name, ext))
        with open(path) as fh:
            return fh.readlines()
    lay = layout.Layout(arch, fmt, None, 64, True, name, frozenset())
    return lay.load(lines("sym"), lines("dis"), lines("hdr"))


# (fixture, arch, format, fragInList's address, size, instructions, branches,
#  and its one loop's figures)
CASES = [
    ("x86_64-llvm", "x86_64", "elf", 0x24360, 146, 34, 8,
     dict(blocks=4, insns=9, branches=4, bytes=39, ranges=2, hdr_m32=0, hdr_m64=32,
          windows=2, windows_min=2, lines=2, lines_min=1, pad=7, pad_ft=False, jcc=1,
          jccw=2, key="for.cond.1")),
    ("x86_64-gnu", "x86_64", "elf", 0x24360, 146, 34, 8,
     dict(blocks=4, insns=9, branches=4, bytes=39, ranges=2, hdr_m32=0, hdr_m64=32,
          windows=2, windows_min=2, lines=2, lines_min=1, pad=7, pad_ft=False, jcc=1,
          jccw=2, key="for.cond.1")),
    ("aarch64-llvm", "aarch64", "elf", 0x22378, 120, 30, 8,
     dict(blocks=4, insns=8, branches=4, bytes=32, ranges=2, hdr_m32=4, hdr_m64=36,
          windows=3, windows_min=2, lines=2, lines_min=1, pad=0, brden=50.0, maxbr=2,
          key="for.cond.1")),
    ("arm32-llvm", "arm32", "elf", 0x1C778, 156, 39, 8,
     dict(blocks=4, insns=12, branches=4, bytes=48, ranges=2, hdr_m32=8, hdr_m64=40,
          windows=4, windows_min=3, lines=2, lines_min=1, pad=0, brden=33.3, maxbr=2,
          key="for.cond.1")),
    # Mach-O keeps no L<sym>__<blk> labels, so the loop is keyed by position.
    ("aarch64-macho", "aarch64", "macho", 0x100007EB8, 120, 30, 8,
     dict(blocks=4, insns=8, branches=4, bytes=32, ranges=2, hdr_m32=4, hdr_m64=36,
          windows=3, windows_min=2, lines=2, lines_min=1, pad=0, brden=50.0, maxbr=2,
          key="#0")),
]


class RealOutputTest(unittest.TestCase):
    def test_functions_and_loop(self):
        for name, arch, fmt, addr, size, insns, br, loop in CASES:
            with self.subTest(name):
                lay = load(name, arch, fmt)
                self.assertEqual([f.name for f in lay.funcs], [PREV, FUNC])
                f = lay.funcs[1]
                self.assertEqual((f.addr, f.size, f.insns, f.br), (addr, size, insns, br))
                self.assertEqual(len(f.loops), 1)
                lp = f.loops[0]
                self.assertEqual({k: lp.get(k) for k in loop}, loop)
                self.assertEqual((lp["depth"], lp["innermost"]), (1, True))

    def test_expect_seed(self):
        for name, arch, fmt, *_ in CASES:
            with self.subTest(name):
                rows = {r["name"]: r for r in load(name, arch, fmt).expect_seed(7, "phase")}
                self.assertTrue(rows[FUNC]["ok"], rows[FUNC])
                self.assertEqual(rows[FUNC]["status"], "ok")
                # Not seed 8: it happens to give fragInList the same phase as 7.
                wrong = {r["name"]: r for r in load(name, arch, fmt).expect_seed(9, "phase")}
                self.assertFalse(wrong[FUNC]["ok"], wrong[FUNC])

    def test_gnu_matches_llvm(self):
        a, b = load("x86_64-llvm", "x86_64", "elf"), load("x86_64-gnu", "x86_64", "elf")
        self.assertEqual([(f.name, f.addr, f.size, f.insns, f.br, f.hits) for f in a.funcs],
                         [(f.name, f.addr, f.size, f.insns, f.br, f.hits) for f in b.funcs])


if __name__ == "__main__":
    unittest.main()
