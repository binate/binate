"""Tests for layout_arm.py: aarch64 and arm32 classification and branch
tables, on llvm-objdump (ELF and --macho) and GNU objdump text.

Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_arm as arm
from layout_disasm import CODE, FILL, NOP, GAP, DATA


def word(v):
    return v.to_bytes(4, "little")


A64 = arm.decode_aarch64
A32 = arm.decode_arm32
ANY = word(0x12345678)


class Aarch64Test(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(A64("brk\t#0x5eed", word(0xD42BDDA0))[0], FILL)
        self.assertEqual(A64("brk\t#0x1", word(0xD4200020))[:3], (CODE, None, False))
        self.assertEqual(A64("nop", word(0xD503201F))[0], NOP)
        self.assertEqual(A64("udf\t#0x0", word(0))[0], GAP)
        self.assertEqual(A64("<unknown>", word(0xD4D4D4D4))[0], GAP)
        self.assertEqual(A64(".long\t0x4d2e7472", None)[0], DATA)
        self.assertEqual(A64("<unknown>", ANY)[:2], (CODE, None))
        self.assertEqual(A64(".inst\t0x12345678 ; undefined", ANY)[0], CODE)

    def test_branch_table(self):
        cases = [("b\t0x18ec4 <L__b>", "b", False, "0x18ec4 <L__b>"),
                 ("b.eq\t0x18eb0 <L__t>", "b.cond", True, "0x18eb0 <L__t>"),
                 ("b.eq\t18eb0 <L__t>  // b.none", "b.cond", True, "18eb0 <L__t>"),
                 ("bl\t_bn_F1_4_main1_1_f", "bl", True, "_bn_F1_4_main1_1_f"),
                 ("br\tx17", "br", False, None), ("blr\tx17", "blr", True, None),
                 ("ret", "ret", False, None), ("retaa", "ret", False, None),
                 ("cbz\tx1, 0x100000624", "cbz/cbnz", True, "x1, 0x100000624"),
                 ("tbnz\tw9, #0x3f, 0x100000e68", "tbz/tbnz", True, "w9, #0x3f, 0x100000e68"),
                 ("mov\tx29, sp", None, True, None)]
        for text, kind, ft, tgt in cases:
            with self.subTest(text=text):
                self.assertEqual(A64(text, ANY)[1:4], (kind, ft, tgt))
        self.assertTrue(A64("bl\t0x10", ANY)[4])
        self.assertEqual(set(arm.BRANCH_KINDS["aarch64"]),
                         {"b", "b.cond", "bl", "br", "blr", "ret", "cbz/cbnz", "tbz/tbnz"})


class Arm32Test(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(A32("bkpt\t#0x5eed", word(0xE125EE7D))[0], FILL)
        self.assertEqual(A32("bkpt\t0x5eed", word(0xE125EE7D))[0], FILL)
        self.assertEqual(A32("bkpt\t#0x0", word(0xE1200070))[:3], (CODE, None, False))
        for raw in (word(0xE320F000), word(0xE1A00000), b"\x00\xbf", b"\xc0\x46"):
            self.assertEqual(A32("nop", raw)[0], NOP)
        self.assertEqual(A32("andeq\tr0, r0, r0", word(0))[0], GAP)
        self.assertEqual(A32("ldrble\tsp, [r4], #1236", word(0xD4D4D4D4))[0], GAP)
        self.assertEqual(A32(".word\t0x0006a7bc", word(0x6A7BC))[0], DATA)
        self.assertEqual(A32(".short\t0x1", b"\x01\x00")[0], DATA)
        self.assertEqual(A32("", ANY)[0], CODE)

    def test_branch_table(self):
        cases = [("b\t0x40000084 <L__m> @ imm = #0x18", "b", False, True),
                 ("b.n\t10abc <register_tm_clones>", "b", False, True),
                 ("bne\t0x40000068 <L__t>", "b<cc>", True, True),
                 ("ble\t0x10", "b<cc>", True, True), ("bls\t0x10", "b<cc>", True, True),
                 ("blo\t0x10", "b<cc>", True, True), ("beq.w\t0x10", "b<cc>", True, True),
                 ("bl\t0x10b00 <f>", "bl", True, True), ("bleq\t0x10", "bl", True, True),
                 ("blx\t0x10b00 <f>", "blx", True, True), ("blx\t10b00 <f>", "blx", True, True),
                 ("blx\tr12", "blx", True, False), ("blx\tip", "blx", True, False),
                 ("bx\tlr", "bx", False, False), ("bx\tr3", "bx", False, False),
                 ("bxeq\tlr", "bx", True, False),
                 ("pop\t{r11, pc}", "pop{pc}", False, False),
                 ("pop.w\t{r4, r5, pc}", "pop{pc}", False, False),
                 ("popne\t{r4, pc}", "pop{pc}", True, False),
                 ("pop\t{r4, r5}", None, True, False),
                 ("ldm\tsp!, {r4, pc}", "pop{pc}", False, False),
                 ("ldm\tr5, {r0, r1}", None, True, False),
                 ("ldm\tr5, {r0, pc}", "pc-write", False, False),
                 ("ldr\tpc, [ip, #1788]!", "pc-write", False, False),
                 ("mov\tpc, lr", "pc-write", False, False),
                 ("cbz\tr3, 0x10ae4 <f+0x28>", "cbz/cbnz", True, True),
                 ("bic\tr0, r0, #1", None, True, False), ("bfc\tr0, #0, #4", None, True, False),
                 ("ldr\tr0, [pc, #8]", None, True, False), ("str\tpc, [sp]", None, True, False),
                 # Conditional pc writes fall through when the condition fails.
                 ("ldmeq\tsp!, {r4, pc}", "pop{pc}", True, False),
                 ("ldmiaeq\tr0, {r1, pc}", "pc-write", True, False),
                 ("ldmeqia\tr0, {r1, pc}", "pc-write", True, False),
                 ("ldmib\tr0, {r1, pc}", "pc-write", False, False),
                 ("moveq\tpc, lr", "pc-write", True, False),
                 ("movseq\tpc, lr", "pc-write", True, False),
                 ("moveqs\tpc, lr", "pc-write", True, False),
                 ("movs\tpc, lr", "pc-write", False, False),
                 ("ldrne\tpc, [sp], #4", "pc-write", True, False),
                 ("addeq\tpc, pc, r0, lsl #2", "pc-write", True, False),
                 # adcs / lsls end in a condition's spelling but are the S form.
                 ("adcs\tpc, r0, r1", "pc-write", False, False),
                 ("lsls\tpc, r0, #1", "pc-write", False, False),
                 ("subs\tpc, lr, #4", "pc-write", False, False)]
        for text, kind, ft, has_tgt in cases:
            with self.subTest(text=text):
                cls, k, f, tgt, call, _ = A32(text, ANY)
                self.assertEqual((cls, k, f, tgt is not None), (CODE, kind, ft, has_tgt))
                self.assertEqual(call, kind in ("bl", "blx"))
        self.assertEqual(A32("b\t40000068 <L__t>", ANY)[3], "40000068 <L__t>")

    def test_rules_object(self):
        r = arm.Rules("arm32")
        self.assertEqual(r.decode, arm.decode_arm32)
        self.assertFalse(r.HAS_ERRATUM)
        self.assertEqual(r.BRANCH_KINDS[:6], ("b", "b<cc>", "bl", "blx", "bx", "pop{pc}"))


if __name__ == "__main__":
    unittest.main()
