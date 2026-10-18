"""Tests for layout_x86.py: classification, branch kinds, macro-fusion and
the JCC-erratum rule, on llvm-objdump and GNU objdump AT&T text.

Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_disasm as ld
import layout_x86 as x86
from layout_disasm import CODE, FILL, NOP, GAP, DATA, Rec


def dec(text, raw=b"\x48\x89\xe5"):
    return x86.decode(text, raw)


class ClassTest(unittest.TestCase):
    def test_filler_pad_gap(self):
        self.assertEqual(dec("int3", b"\xcc")[0], FILL)
        for raw in (b"\x90", b"\x66\x90", b"\x0f\x1f\x00", b"\x66\x0f\x1f\x44\x00\x00",
                    b"\x66\x2e\x0f\x1f\x84\x00\x00\x00\x00\x00",
                    b"\x66\x66\x2e\x0f\x1f\x84\x00\x00\x00\x00\x00"):
            with self.subTest(raw=raw):
                self.assertEqual(dec("nop", raw)[0], NOP)
        self.assertEqual(dec("pause", b"\xf3\x90")[0], CODE)
        self.assertEqual(dec("addb %al,(%rax)", b"\x00\x00")[0], GAP)
        self.assertEqual(dec(".byte 0x1", b"\x01")[0], DATA)
        self.assertEqual(dec("(bad)", b"\x06")[:3], (CODE, None, True))

    def test_branch_kinds_llvm(self):
        cases = [("je\t0x193a8 <Lbn_f__b>", ("jcc", True, "0x193a8 <Lbn_f__b>")),
                 ("jmp\t0x193bb <Lbn_f__c>", ("jmp", False, "0x193bb <Lbn_f__c>")),
                 ("jmpq\t*%rax", ("ijmp", False, None)),
                 ("callq\t0x21be0 <bn_F1_1_p1_1_f>", ("call", True, "0x21be0 <bn_F1_1_p1_1_f>")),
                 ("callq\t*0x70d13(%rip)          # 0x89fb8 <write>", ("icall", True, None)),
                 ("retq", ("ret", False, None)),
                 ("jrcxz\t0x10", ("jcc", True, "0x10")),
                 ("ud2", (None, False, None)),
                 ("movq\t%rax, %rbx", (None, True, None))]
        for text, (kind, ft, tgt) in cases:
            with self.subTest(text=text):
                cls, k, f, t, call, _ = dec(text)
                self.assertEqual((cls, k, f, t), (CODE, kind, ft, tgt))
                self.assertEqual(call, kind in ("call", "icall"))

    def test_branch_kinds_gnu(self):
        cases = [("je     193a8 <Lbn_f__b>", "jcc"), ("jmp    193bb <x>", "jmp"),
                 ("notrack jmp *%rax", "ijmp"), ("bnd jmp *0x8(%rax)", "ijmp"),
                 ("call   21be0 <f>", "call"), ("call   *%r11", "icall"), ("ret", "ret"),
                 ("repz ret", "ret"), ("rep stos %al,%es:(%rdi)", None)]
        for text, kind in cases:
            with self.subTest(text=text):
                self.assertEqual(dec(text)[1], kind)

    def test_jcc_condition(self):
        self.assertEqual(dec("jz\t0x10")[5], "e")
        self.assertEqual(dec("jnae    10")[5], "b")
        self.assertIsNone(dec("jecxz\t0x10")[5])


class FusionTest(unittest.TestCase):
    def test_families(self):
        cases = [("cmpq", "%r10, %r9", "cmp"), ("cmp", "%r10,%r9", "cmp"),
                 ("cmpq", "$0x0, %r9", "cmp"), ("cmpq", "0x60(%rsp), %r9", "cmp"),
                 ("cmpq", "$0x0, -0x10(%r12)", None), ("cmpb", "$0x0, 0x70f76(%rip)", None),
                 ("testq", "%rax, %rax", "test"), ("addq", "$0x1, %rdi", "add"),
                 ("addq", "%rax, 0x8(%rsp)", None), ("subl", "$1, %eax", "sub"),
                 ("andq", "%rax, %rbx", "and"), ("incl", "%eax", "inc"),
                 ("decq", "(%rax)", None), ("andnq", "%rax, %rbx, %rcx", None),
                 ("cmpsb", "%es:(%rdi), (%rsi)", None), ("movq", "%rax, %rbx", None),
                 # A segment-override absolute address is memory, not a register.
                 ("cmpq", "$0x0, %fs:0x10", None), ("addq", "$0x1, %fs:0x28", None),
                 ("incq", "%fs:0x10", None), ("cmpq", "%rax, %fs:0x10", "cmp")]
        for mnem, ops, fam in cases:
            with self.subTest(mnem=mnem, ops=ops):
                self.assertEqual(x86.fusion_family(mnem, ops), fam)

    def test_pairs(self):
        self.assertTrue(x86.fuses("cmp", "l"))
        self.assertFalse(x86.fuses("cmp", "s"))
        self.assertFalse(x86.fuses("add", "o"))
        self.assertTrue(x86.fuses("test", "o"))
        self.assertTrue(x86.fuses("inc", "ne"))
        self.assertFalse(x86.fuses("dec", "b"))
        self.assertFalse(x86.fuses(None, "e"))

    def test_split_operands(self):
        self.assertEqual(x86.split_operands("%rax, (%rbx,%rcx,8)"), ["%rax", "(%rbx,%rcx,8)"])


def rec(addr, size, text):
    cls, kind, ft, tgt, call, fuse = x86.decode(text, bytes([0x48] * size))
    return Rec(addr, size, cls, kind, ft, None, call, fuse)


class ErratumTest(unittest.TestCase):
    def test_jcc_ending_on_boundary(self):
        r = [rec(0x1A, 6, "jne\t0x40")]
        self.assertEqual(x86.units(r), [(0x1A, 6, False)])
        self.assertTrue(x86.hit(0x1A, 6))
        self.assertEqual(list(x86.hit_windows(0x1A, 6)), [0])

    def test_jcc_crossing(self):
        self.assertTrue(x86.hit(0x1E, 4))
        self.assertEqual(list(x86.hit_windows(0x1E, 4)), [0, 1])
        self.assertFalse(x86.hit(0x20, 6))
        self.assertFalse(x86.hit(0x10, 6))

    def test_fused_pair_crossing(self):
        # cmp at 0x1c-0x1f, jl at 0x20-0x25: the jcc alone starts on the
        # boundary and is not hit, but the fused pair crosses it.
        r = [rec(0x1C, 4, "cmpq\t%r10, %r9"), rec(0x20, 6, "jl\t0x80")]
        self.assertFalse(x86.hit(0x20, 6))
        units = x86.units(r)
        self.assertEqual(units, [(0x1C, 10, True)])
        self.assertTrue(x86.hit(*units[0][:2]))

    def test_unfusible_pair(self):
        r = [rec(0x1C, 4, "cmpq\t$0x0, 0x8(%rax)"), rec(0x20, 6, "jl\t0x80")]
        self.assertEqual(x86.units(r), [(0x20, 6, False)])
        r = [rec(0x1C, 4, "cmpq\t%r10, %r9"), rec(0x20, 6, "js\t0x80")]
        self.assertEqual(x86.units(r), [(0x20, 6, False)])
        gap = [rec(0x1A, 4, "cmpq\t%r10, %r9"), rec(0x20, 6, "jl\t0x80")]
        self.assertEqual(x86.units(gap), [(0x20, 6, False)])

    def test_ret_and_call_units(self):
        r = [rec(0x3F, 1, "retq"), rec(0x40, 5, "callq\t0x100"), rec(0x45, 3, "movq\t%rax, %rbx")]
        self.assertEqual([u[:2] for u in x86.units(r)], [(0x3F, 1), (0x40, 5)])
        self.assertTrue(x86.hit(0x3F, 1))
        self.assertFalse(x86.hit(0x40, 5))


# The same code as llvm-objdump and GNU objdump -w print it: a jcc ending on
# 0x20, a fused cmp+jcc pair crossing 0x40 whose jcc alone does not, and a
# 3-byte ret crossing 0x60.
LLVM_TEXT = """\
Disassembly of section .text:

0000000000001000 <f>:
    1000: 48 89 e5                     \tmovq\t%rsp, %rbp
    101a: 0f 85 e0 ff ff ff            \tjne\t0x1000 <f>
    1020: 90                           \tnop
    103d: 4d 39 d1                     \tcmpq\t%r10, %r9
    1040: 7c be                        \tjl\t0x1000 <f>
    105f: c2 08 00                     \tretq\t$0x8
"""

GNU_TEXT = """\
Disassembly of section .text:

0000000000001000 <f>:
    1000:\t48 89 e5             \tmov    %rsp,%rbp
    101a:\t0f 85 e0 ff ff ff    \tjne    1000 <f>
    1020:\t90                   \tnop
    103d:\t4d 39 d1             \tcmp    %r10,%r9
    1040:\t7c be                \tjl     1000 <f>
    105f:\tc2 08 00             \tret    $0x8
"""


class DisassemblyErratumTest(unittest.TestCase):
    def test_both_syntaxes(self):
        for text in (LLVM_TEXT, GNU_TEXT):
            with self.subTest(text=text[:60]):
                recs = [r for _, r in ld.parse_disasm(text.splitlines(True), x86.decode,
                                                      "elf", {"f": 0x1000})
                        if r.cls == CODE]
                units = x86.units(recs)
                self.assertEqual([u[:3] for u in units],
                                 [(0x101A, 6, False), (0x103D, 5, True), (0x105F, 3, False)])
                self.assertEqual([x86.hit(s, n) for s, n, _ in units], [True, True, True])
                self.assertFalse(x86.hit(0x1040, 2))
                self.assertEqual(recs[1].tgt, 0x1000)


if __name__ == "__main__":
    unittest.main()
