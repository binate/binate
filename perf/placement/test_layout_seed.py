"""Tests for layout_seed.py (--expect-seed) on the x86-64 fixture program from
layout_testutil.py and small hand-built programs: exact filler, the
first-of-object rule with and without merged linker fill, the #[c_export]
first-entry rule, filler that is missing or replaced, displaced entries,
names outside the mangling grammar, the filler / gap byte split the seed
settles, and Mach-O's stripped c_export aliases.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_testutil as tu
from layout_disasm import FILL, GAP
from layout_testutil import Prog
from test_layout import load
from test_layout_names import UNPARSED


def rows_of(lay, seed, mode="phase"):
    return {r["name"]: r for r in lay.expect_seed(seed, mode)}


class ExpectSeedTest(unittest.TestCase):
    def rows(self, prog, seed, mode="phase", style="llvm"):
        return rows_of(load(prog, style), seed, mode)

    def test_phase_pass(self):
        rows = self.rows(tu.x86_program(7), 7)
        self.assertEqual(len(rows), 5)
        self.assertTrue(all(r["ok"] and r["status"] == "ok" for r in rows.values()))
        self.assertTrue(rows[tu.F1]["first"] and rows[tu.G1]["first"])
        self.assertFalse(rows[tu.F2]["first"] or rows[tu.G2]["first"])

    def test_shift_pass_and_mode_mismatch(self):
        prog = tu.x86_program(11, "shift")
        self.assertTrue(all(r["ok"] for r in self.rows(prog, 11, "shift").values()))
        self.assertFalse(all(r["ok"] for r in self.rows(prog, 11, "phase").values()))

    def test_wrong_seed_fails(self):
        rows = self.rows(tu.x86_program(7), 8)
        self.assertTrue(any(r["status"] == "FAIL" for r in rows.values()))

    def test_unseeded(self):
        prog = tu.x86_program(0)
        self.assertTrue(all(r["ok"] for r in self.rows(prog, 0).values()))
        self.assertFalse(all(r["ok"] for r in self.rows(prog, 7).values()))

    def test_c_export_alias_is_first_entry(self):
        r = self.rows(tu.x86_program(7), 7)[tu.F3]
        self.assertEqual(r["entry_name"], "cexp")
        self.assertEqual(r["phase"], tu.placehash.entry_phase(7, tu.F3, 16))

    def test_linker_int3_gap_counts_as_at_least(self):
        prog = tu.x86_program(7, gap="int3")
        rows = self.rows(prog, 7)
        g1 = rows[tu.G1]
        self.assertGreater(g1["fill"], g1["least_fill"])
        self.assertEqual(g1["status"], "ok>=")
        self.assertTrue(all(r["ok"] for r in rows.values()))

    def test_wrong_filler_fails(self):
        for mode in ("phase", "shift"):
            for key in (tu.F2, tu.G2):
                with self.subTest(mode=mode, key=key):
                    prog = tu.x86_program(7, mode, extra={key: 16})
                    rows = self.rows(prog, 7, mode)
                    self.assertEqual(rows[key]["status"], "FAIL")
                    self.assertEqual(rows[key]["fill"], rows[key]["want_fill"] + 16)

    def test_extra_filler_after_nop_gap_fails(self):
        # Behind GNU ld's NOP gap fill, an object's first filler cannot have
        # merged with the linker's fill, so a longer run is wrong.
        rows = self.rows(tu.x86_program(7, extra={tu.G1: 16}), 7)
        self.assertEqual(rows[tu.G1]["status"], "FAIL")

    def test_longer_first_filler_fails_on_arm(self):
        # An object that starts right where the previous one ends (shift
        # mode, whose objects are not 64-aligned): on x86-64 lld's INT3 gap
        # fill could have lengthened the first filler run, but no linker
        # fills with BRK #0x5EED.
        def prog(arch, extra):
            p = Prog(arch, 0x100C if arch == "aarch64" else 0x100F)
            p.sym("c_code")
            p.op(0xD65F03C0 if arch == "aarch64" else b"\xc3",
                 "ret" if arch == "aarch64" else "retq")
            p.start_object(16, "nop" if arch == "aarch64" else "int3")
            p.placed(tu.G1, 11, "shift", extra)
            p.sym(tu.G1)
            p.op(0xD65F03C0 if arch == "aarch64" else b"\xc3",
                 "ret" if arch == "aarch64" else "retq")
            return p
        for arch, extra, status in (("aarch64", 0, "ok"), ("aarch64", 64, "FAIL"),
                                    ("x86_64", 0, "ok"), ("x86_64", 16, "ok>=")):
            with self.subTest(arch=arch, extra=extra):
                p = prog(arch, extra)
                self.assertEqual(self.rows(p, 11, "shift")[tu.G1]["status"], status)

    def test_zeroed_filler_fails(self):
        # Zero bytes in place of the filler keep every entry where it was, so
        # the phase is right; the filler is what must be checked.
        for mode, seed in (("phase", 7), ("shift", 13)):
            for key in (tu.F2, tu.G1):
                with self.subTest(mode=mode, key=key):
                    rows = self.rows(tu.x86_program(seed, mode, zero={key}), seed, mode)
                    r = rows[key]
                    self.assertGreater(r["want_fill"] if key == tu.F2 else r["least_fill"], 0)
                    self.assertEqual(r["fill"], 0)
                    self.assertEqual(r["status"], "FAIL")
                    if mode == "phase":
                        self.assertEqual(r["dphase"], 0)
                    others = [x for k, x in rows.items() if k != key]
                    self.assertTrue(all(x["ok"] for x in others))

    def test_zeroed_filler_fails_on_aarch64(self):
        def prog(zero):
            p = Prog("aarch64", 0x18D40)
            for key in ("bn_F1_4_main1_1_a", "bn_F1_4_main1_1_b"):
                p.placed(key, 7, "phase", zero=key in zero)
                p.sym(key)
                p.op(0xD2800000, "mov\tx0, #0x0")
                p.op(0xD2800001, "mov\tx1, #0x0")
                p.op(0xD65F03C0, "ret")
            return p
        self.assertTrue(all(r["ok"] for r in self.rows(prog(()), 7).values()))
        r = self.rows(prog({"bn_F1_4_main1_1_b"}), 7)["bn_F1_4_main1_1_b"]
        self.assertEqual((r["want_fill"], r["fill"], r["dphase"]), (60, 0, 0))
        self.assertEqual(r["status"], "FAIL")

    def test_displaced_entry_fails_in_shift_mode(self):
        # The right filler followed by 16 more bytes of NOPs: shift mode has
        # no phase to check, so the entry's position must be.
        p = Prog("x86_64", 0x1000)
        p.placed(tu.F1, 11, "shift")
        p.sym(tu.F1)
        p.op(b"\xc3", "retq")
        p.placed(tu.F2, 11, "shift")
        for _ in range(16):
            p.op(b"\x90", "nop")
        p.sym(tu.F2)
        p.op(b"\xc3", "retq")
        self.assertEqual(self.rows(p, 11, "shift")[tu.F2]["status"], "FAIL")

    def test_gnu_syntax_agrees(self):
        prog = tu.x86_program(7)
        self.assertEqual(self.rows(prog, 7, style="llvm"), self.rows(prog, 7, style="gnu"))

    def test_names_outside_the_grammar_are_checked(self):
        # A name the grammar cannot parse is still a compiled function: its
        # filler is checked by symbol, and the function after it directly
        # follows a placed function, so it is not taken for an object's first.
        for seed, extra in ((7, 0), (7, 16)):
            p = Prog("x86_64", 0x1000)
            for key in (tu.F1, UNPARSED, tu.F2):
                p.placed(key, seed, "phase", extra if key == tu.F2 else 0)
                p.sym(key)
                p.op(b"\xc3", "retq")
            rows = self.rows(p, seed)
            self.assertEqual(list(rows), [tu.F1, UNPARSED, tu.F2])
            self.assertEqual((rows[UNPARSED]["parsed"], rows[UNPARSED]["ok"]), (False, True))
            self.assertFalse(rows[tu.F2]["first"])
            self.assertEqual(rows[tu.F2]["ok"], extra == 0)


class FillSplitTest(unittest.TestCase):
    def test_unseeded_lld_gap_is_gap(self):
        # lld's INT3 between objects, before an unseeded build's first
        # function: not whole filler units, so all gap.
        p = tu.x86_program(0)
        p2 = Prog("x86_64", 0x1000)
        p2.sym(tu.F1)
        p2.op(b"\x31\xc0\xc3", "xorl\t%eax, %eax")
        p2.sym(tu.PKG_A)
        p2.op(b"\xc3", "retq")
        p2.start_object(16, "int3")
        p2.sym(tu.G1)
        p2.op(b"\xc3", "retq")
        for prog in (p, p2):
            lay = load(prog)
            counts = lay.byte_counts()
            self.assertEqual(counts[FILL], 0)
            self.assertEqual(sum(counts.values()), sum(lay.bytes.values()))
        self.assertEqual(load(p2).byte_counts()[GAP], 12)

    def test_int3_before_unplaced_function_is_gap(self):
        p = Prog("x86_64", 0x1000)
        p.sym(tu.F1)
        p.op(b"\xc3", "retq")
        p.int3_to(64)
        p.sym("c_helper")
        p.op(b"\xc3", "retq")
        lay = load(p)
        self.assertEqual((lay.byte_counts()[FILL], lay.byte_counts()[GAP]), (0, 63))

    def test_seed_settles_merged_first_filler(self):
        # Phase mode on lld: the INT3 gap before the 64-aligned object start
        # merges with the first function's filler; whole units of it look
        # like filler until the seed's prediction settles the split.
        prog = tu.x86_program(7, gap="int3")
        lay = load(prog)
        rows = rows_of(lay, 7)
        g1 = rows[tu.G1]
        self.assertEqual(g1["status"], "ok>=")
        want = sum(r["least_fill"] if r["status"] == "ok>=" else r["fill"]
                   for r in rows.values())
        self.assertEqual(lay.byte_counts()[FILL], want)
        unsettled = load(prog).byte_counts()[FILL]
        self.assertGreaterEqual(unsettled, want)


def a64_cexport(seed, strip):
    """aarch64 Mach-O: a, then f behind a #[c_export] alias cx_first whose
    code (a sign extension and a branch) transfers to f.  strip removes the
    alias and turns its code into linker padding, as a dead-strip by a linker
    that keeps each atom's offset modulo the section alignment leaves it."""
    a, f = "bn_F2_3_pkg2_cx1_1_a", "bn_F2_3_pkg2_cx1_5_First"
    p = Prog("aarch64", 0x100000580)
    p.placed(a, seed, "phase")
    p.sym(a)
    p.op(0xD65F03C0, "ret")
    p.placed(f, seed, "phase")
    if strip:
        p.skip(8)
    else:
        p.sym("cx_first")
        p.op(0x93401C00, "sxtb\tx0, w0")
        p.op(0x14000001, "b\t{t}", p.pc + 4)
    p.sym(f)
    p.op(0xD65F03C0, "ret")
    return p, f


class MachoStrippedAliasTest(unittest.TestCase):
    def test_alias_present(self):
        p, f = a64_cexport(7, False)
        r = rows_of(load(p, "macho"), 7)[f]
        self.assertEqual((r["entry_name"], r["status"]), ("cx_first", "ok"))

    def test_stripped_alias_passes_by_its_filler(self):
        p, f = a64_cexport(7, True)
        r = rows_of(load(p, "macho"), 7)[f]
        self.assertEqual((r["entry_name"], r["dphase"]), (f, 8))
        self.assertEqual((r["status"], r["ok"]), ("ok-fill", True))

    def test_stripped_alias_wrong_seed_fails(self):
        p, f = a64_cexport(7, True)
        self.assertEqual(rows_of(load(p, "macho"), 9)[f]["status"], "FAIL")

    def test_elf_has_no_stripped_atoms(self):
        p, f = a64_cexport(7, True)
        self.assertEqual(rows_of(load(p), 7)[f]["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
