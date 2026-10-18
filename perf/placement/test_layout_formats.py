"""End-to-end tests of layout.py on aarch64 (ELF and Mach-O) and arm32
programs from layout_testutil.py, in llvm-objdump, llvm-objdump --macho and
GNU objdump syntax: branch tables, the Arm loop and compare columns, mapping
symbols and literal pools, data after code, local asm labels, Mach-O linker
stubs, and --expect-seed on each.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import argparse
import io
import unittest

import layout
import layout_report as rep
from layout_testutil import Prog
from test_layout import load

A1 = "bn_F1_4_main1_1_a"
A2 = "bn_F1_4_main1_1_b"
A3 = "bn_F1_4_main1_1_c"
APKG = "bn_F1_4_main1_9___Package"
LBODY = "Lbn_F1_4_main1_1_a__for.body.1"


def a64_program(seed, mode="phase", extra=None):
    """One aarch64 object: a (a loop on cbnz), b (calls a), c, descriptor."""
    extra = extra or {}
    p = Prog("aarch64", 0x18D40)
    p.sym("$x", "l      ")
    p.placed(A1, seed, mode, extra.get(A1, 0))
    p.sym(A1)
    p.op(0xA9BF7BFD, "stp\tx29, x30, [sp, #-0x10]!")
    p.op(0xF10000FF, "cmp\tx7, #0x0")
    p.op(0x54000040, "b.eq\t{t}", p.pc + 8)
    p.op(0x14000006, "b\t{t}", p.pc + 12)
    p.label(LBODY)
    p.op(0xD1000421, "sub\tx1, x1, #0x1")
    p.op(0xB5FFFFE1, "cbnz\tx1, {t}", p.pc - 4)
    p.op(0xA8C17BFD, "ldp\tx29, x30, [sp], #0x10")
    p.op(0xD65F03C0, "ret")
    p.placed(A2, seed, mode, extra.get(A2, 0))
    p.sym(A2)
    p.op(0x97FFFFF0, "bl\t{t}", 0x18D40 + 0)
    p.op(0xD63F0220, "blr\tx17")
    p.op(0xD65F03C0, "ret")
    p.placed(A3, seed, mode, extra.get(A3, 0))
    p.sym(A3)
    p.op(0x36000041, "tbz\tw1, #0x0, {t}", p.pc + 8)
    p.op(0xD61F0220, "br\tx17")
    p.op(0xD65F03C0, "ret")
    p.sym(APKG)
    p.op(0xD65F03C0, "ret")
    return p


class Aarch64Test(unittest.TestCase):
    def test_elf_tables(self):
        for style in ("llvm", "gnu"):
            with self.subTest(style=style):
                lay = load(a64_program(7), style)
                s = rep.summary(lay)
                self.assertEqual(s["branches"], {"b": 1, "b.cond": 1, "bl": 1, "br": 1,
                                                 "blr": 1, "ret": 4, "cbz/cbnz": 1,
                                                 "tbz/tbnz": 1, "total": 11})
                self.assertNotIn("erratum", s)
                rows = {r["name"]: r for r in rep.func_rows(lay, [])}
                self.assertEqual(rows[A1]["insns"], 8)
                self.assertEqual(rows[A1]["brden"], 50.0)
                self.assertEqual(lay.window, 16)
                (loop,) = rep.loop_rows(lay, [])
                self.assertEqual((loop["label"], loop["blocks"]), (LBODY, 1))

    def test_arm_loop_columns(self):
        # Arm loops carry branch density, never the x86 erratum columns, in
        # every output and in --compare.
        a, b = load(a64_program(0)), load(a64_program(7))
        (loop,) = rep.loop_rows(a, [])
        self.assertEqual((loop["insns"], loop["branches"], loop["brden"], loop["maxbr"]),
                         (2, 1, 50.0, 1))
        self.assertFalse({"jcc", "jccw", "hits"} & set(loop))
        _, (cl,), _ = rep.compare_rows(a, b, [])
        self.assertEqual((cl["brden_a"], cl["maxbr_b"]), (50.0, 1))
        self.assertFalse(any(k.startswith(("jcc", "hits")) for k in cl))
        ns = argparse.Namespace(loops=True, json=False, tsv=True, expect_seed=None, mode=None)
        out = io.StringIO()
        rep.emit(a, b, None, [], ns, out)
        header = out.getvalue().split("# loops\n", 1)[1].split("\n", 1)[0].split("\t")
        self.assertIn("brden", header)
        self.assertNotIn("hits", header)

    def test_elf_expect_seed(self):
        for mode, seed in (("phase", 7), ("shift", 11)):
            with self.subTest(mode=mode):
                lay = load(a64_program(seed, mode))
                self.assertTrue(all(r["ok"] for r in lay.expect_seed(seed, mode)))
                self.assertFalse(all(r["ok"] for r in lay.expect_seed(seed + 1, mode)))
        lay = load(a64_program(7, extra={A2: 64}))
        self.assertEqual({r["name"]: r["status"] for r in lay.expect_seed(7, "phase")}[A2],
                         "FAIL")

    def test_macho(self):
        lay = load(a64_program(7), "macho")
        self.assertEqual([f.name for f in lay.funcs], [A1, A2, A3, APKG])
        a2 = next(f for f in lay.funcs if f.name == A2)
        self.assertEqual(a2.br, 3)
        self.assertTrue(all(r["status"] == "ok" for r in lay.expect_seed(7, "phase")))
        self.assertFalse(all(r["ok"] for r in lay.expect_seed(8, "phase")))

    def test_macho_stubs_are_counted(self):
        # The --macho run covers __text; the plain run over the stub sections
        # adds them as unnamed code, as ELF's .plt is.
        p = a64_program(7)
        stubs = ("Disassembly of section __TEXT,__stubs:\n\n%016x <__stubs>:\n"
                 "%x: 90000070    \tadrp\tx16, 0x100034000\n"
                 "%x: f9400210    \tldr\tx16, [x16]\n"
                 "%x: d61f0200    \tbr\tx16\n") % ((p.pc,) + tuple(range(p.pc, p.pc + 12, 4)))
        lay = layout.Layout("aarch64", "macho", path="prog")
        lay.load(p.symtab("macho").splitlines(True),
                 (p.disasm("macho") + stubs).splitlines(True),
                 p.headers("macho") + ["  2 __stubs %08x %016x TEXT" % (12, p.pc)])
        s = rep.summary(lay)
        self.assertEqual(list(s["sections"]), ["__TEXT,__text", "__TEXT,__stubs"])
        self.assertEqual(s["branches"]["br"], 2)
        self.assertEqual(s["unnamed_code"], 0)
        self.assertEqual(s["instructions"], sum(f.insns for f in lay.funcs) + 3)

    def test_macho_dead_strip_tolerance(self):
        # 64 extra filler bytes keep every phase but change the fill count, as
        # a dead-stripped atom does: Mach-O checks phase only, ELF fails it.
        prog = a64_program(7, extra={A2: 64})
        rows = {r["name"]: r for r in load(prog, "macho").expect_seed(7, "phase")}
        self.assertEqual((rows[A2]["status"], rows[A2]["ok"]), ("ok-phase", True))
        shift = {r["name"]: r for r in load(a64_program(11, "shift", {A2: 4}),
                                            "macho").expect_seed(11, "shift")}
        self.assertEqual((shift[A2]["status"], shift[A2]["ok"]), ("inexact", True))

    def test_macho_shift_fails_when_most_rows_differ(self):
        # A wrong seed or an unseeded build leaves most fillers different, which
        # dead-stripped atoms alone do not explain.
        for prog, seed in ((a64_program(11, "shift"), 12), (a64_program(0), 11)):
            rows = load(prog, "macho").expect_seed(seed, "shift")
            self.assertGreater(sum(r["status"] == "FAIL" for r in rows), len(rows) // 2)

    def test_macho_phase_reports_displacement(self):
        # An object the link moved by 16 bytes, as a linker that does not keep
        # each atom's offset modulo the section alignment can.
        prog = a64_program(7)
        prog.items = [(a + 16, raw, text, None if t is None else t + 16, data)
                      for a, raw, text, t, data in prog.items]
        prog.syms = [(a + 16, n, fl) for a, n, fl in prog.syms]
        prog.pc += 16
        rows = load(prog, "macho").expect_seed(7, "phase")
        self.assertTrue(all(r["status"] == "FAIL" and r["dphase"] == 16 for r in rows))


R1 = "bn_F1_4_main1_1_r"
R2 = "bn_F1_4_main1_1_s"
RPKG = "bn_F1_4_main1_9___Package"


def arm32_program(seed, mode="phase"):
    """A bare-metal-style image: one object (r with a literal pool, s), an
    assembly memcpy with a local loop label, then rodata in .text."""
    p = Prog("arm32", 0x40000000)
    p.sym("$a", "l      ")
    p.placed(R1, seed, mode)
    p.sym(R1)
    p.op(0xE92D4800, "push\t{r11, lr}")
    p.op(0xE59F0008, "ldr\tr0, [pc, #0x8]")
    p.op(0x1A000000, "bne\t{t}", p.pc + 8)
    p.op(0xE8BD8800, "pop\t{r11, pc}")
    p.label("Lbn_F1_4_main1_1_r__if.then.1")
    p.op(0xE12FFF1E, "bx\tlr")
    p.sym("$d", "l      ")
    p.data(b"\x78\x56\x34\x12", ".word\t0x12345678")
    p.sym("$a", "l      ")
    p.placed(R2, seed, mode)
    p.sym(R2)
    p.op(0xEBFFFFF0, "bl\t{t}", 0x40000000)
    p.op(0xE12FFF3C, "blx\tr12")
    p.op(0xE8BD8800, "pop\t{r11, pc}")
    p.sym(RPKG)
    p.op(0xE12FFF1E, "bx\tlr")
    p.sym("memcpy")
    p.op(0xE3520000, "cmp\tr2, #0")
    p.sym("memcpy_loop", "l      ")
    p.op(0xE4D13001, "ldrb\tr3, [r1], #1")
    p.op(0xE2522001, "subs\tr2, r2, #1")
    p.op(0x1AFFFFFC, "bne\t{t}", p.pc - 8)
    p.op(0xE12FFF1E, "bx\tlr")
    p.sym("lstr_0", "l      ")
    p.op(0x746E6975, "strbtvc\tr6, [lr], #-2421")
    p.op(0x00000000, "andeq\tr0, r0, r0")
    p.sym("bn_G1_4_main1_1_x", " w     ")
    p.op(0x6C6F6F62, "stclvs\tp15, c6, [pc], #-392")
    return p


class Arm32Test(unittest.TestCase):
    def test_tables_and_regions(self):
        for style in ("llvm", "gnu"):
            with self.subTest(style=style):
                lay = load(arm32_program(7), style)
                f = {x.name: x for x in lay.funcs}
                self.assertEqual(list(f), [R1, R2, RPKG, "memcpy"])
                self.assertEqual(f[R1].size, 24)
                self.assertEqual(f[R1].insns, 5)
                memcpy = f["memcpy"]
                self.assertTrue(memcpy.cut)
                self.assertEqual((memcpy.size, memcpy.insns), (20, 5))
                self.assertEqual(lay.bytes["data"], 4 + 12)
                s = rep.summary(lay)
                self.assertEqual(s["branches"]["b<cc>"], 2)
                self.assertEqual(s["branches"]["pop{pc}"], 2)
                self.assertEqual(s["branches"]["bx"], 3)
                self.assertEqual((s["branches"]["bl"], s["branches"]["blx"]), (1, 1))
                self.assertEqual(len(memcpy.loops), 1)

    def test_expect_seed(self):
        for mode, seed in (("phase", 7), ("shift", 11)):
            with self.subTest(mode=mode):
                lay = load(arm32_program(seed, mode))
                rows = lay.expect_seed(seed, mode)
                self.assertEqual([r["name"] for r in rows], [R1, R2])
                self.assertTrue(all(r["ok"] for r in rows))
                self.assertFalse(all(r["ok"] for r in lay.expect_seed(seed, "phase"
                                                                       if mode == "shift"
                                                                       else "shift")))


if __name__ == "__main__":
    unittest.main()
