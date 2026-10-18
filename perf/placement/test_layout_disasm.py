"""Tests for layout_disasm.py: header detection, the disassembler commands,
symbol-table and disassembly parsing in each supported syntax, symbol roles
and branch-target resolution.

Hand-written snippets only; no binaries or disassemblers are needed.
Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import struct
import unittest

import layout_arm
import layout_disasm as ld
import layout_x86


def elf_head(machine, ei_class=2):
    head = bytearray(64)
    head[:4] = b"\x7fELF"
    head[4], head[5] = ei_class, 1
    struct.pack_into("<H", head, 18, machine)
    return bytes(head)


class DetectTest(unittest.TestCase):
    def test_elf(self):
        self.assertEqual(ld.detect(elf_head(62)), ("elf", "x86_64"))
        self.assertEqual(ld.detect(elf_head(183)), ("elf", "aarch64"))
        self.assertEqual(ld.detect(elf_head(40, 1)), ("elf", "arm32"))

    def test_macho(self):
        head = b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C) + bytes(56)
        self.assertEqual(ld.detect(head), ("macho", "aarch64"))

    def test_rejects(self):
        for head in (elf_head(8), b"MZ" + bytes(62), bytes(64)):
            with self.assertRaises(ValueError):
                ld.detect(head)

    def test_truncated(self):
        # A short file is a ValueError (which layout.py reports with exit 2),
        # never a struct.error or IndexError.
        for head in (elf_head(62)[:12], elf_head(62)[:19], b"\x7fELF",
                     b"\xcf\xfa\xed\xfe\x0c"):
            with self.subTest(head=head):
                with self.assertRaisesRegex(ValueError, "truncated"):
                    ld.detect(head)

    def test_pick_tool(self):
        have = {"objdump": "/usr/bin/objdump"}
        self.assertEqual(ld.pick_tool("elf", "x86_64", have.get), ("/usr/bin/objdump", "gnu"))
        have["llvm-objdump-18"] = "/usr/bin/llvm-objdump-18"
        self.assertEqual(ld.pick_tool("elf", "x86_64", have.get),
                         ("/usr/bin/llvm-objdump-18", "llvm"))
        with self.assertRaises(RuntimeError):
            ld.pick_tool("macho", "aarch64", {"objdump": "x"}.get)
        (cmd,) = ld.disasm_cmds("llvm-objdump", "llvm", "elf", "b", "arm32")
        self.assertIn("--mattr=+hwdiv-arm", cmd)
        self.assertEqual(ld.disasm_cmds("llvm-objdump", "llvm", "macho", "b"),
                         [["llvm-objdump", "-d", "--macho", "b"]])
        (cmd,) = ld.disasm_cmds("objdump", "gnu", "elf", "b")
        self.assertIn("-w", cmd)

    def test_macho_stub_sections(self):
        # The --macho layout covers only __text; the linker stubs, Mach-O's
        # counterpart of ELF's .plt (which -d covers), get a plain run.
        headers = ld.parse_sections(MACHO_HEADERS)
        self.assertEqual(ld.exec_sections(headers), ["__text", "__stubs", "__stub_helper"])
        self.assertEqual(ld.disasm_cmds("llvm-objdump", "llvm", "macho", "b", "aarch64", headers),
                         [["llvm-objdump", "-d", "--macho", "b"],
                          ["llvm-objdump", "-d", "--section=__stubs", "--section=__stub_helper",
                           "b"]])


MACHO_HEADERS = """\
Sections:
Idx Name            Size     VMA              Type
  0 __text          0002821c 0000000100000580 TEXT
  1 __stubs         000005a0 000000010002879c TEXT
  2 __stub_helper   00000090 0000000100028d3c TEXT
  3 __const         00002693 0000000100028dd0 DATA
  9 __bss           00000020 0000000100038000 BSS
""".splitlines()

SYMTAB_LLVM = """\
fk:\tfile format elf64-x86-64

SYMBOL TABLE:
0000000000000000 l    df *ABS*\t0000000000000000 crt1.o
0000000000019280 l    d  .text\t0000000000000000 .text
00000000000193a8 l       .text\t0000000000000000 Lbn_F1_4_main1_1_f__if.then.1
0000000000019380 g     F .text\t0000000000000000 bn_F1_4_main1_1_f
0000000000089bd0  w      .data.rel.ro\t0000000000000000 __handle.bn_F1_4_main1_1_f
0000000000000000       F *UND*\t0000000000000000 write@GLIBC_2.2.5
"""

SYMTAB_GNU = """\
0000000000019380 g     F .text\t0000000000000000              bn_F1_4_main1_1_f
0000000000019390 g     F .text\t0000000000000000              .hidden helper
0000000000000000       F *UND*\t0000000000000000              write@GLIBC_2.2.5
"""

SYMTAB_MACHO = """\
SYMBOL TABLE:
0000000100006524 g     F __TEXT,__text _main
0000000100000e94  w    F __TEXT,__text _bn_F1_4_main1_1_f
0000000100028de8 l     O __TEXT,__const ___typeinfo_name.bn_S0_1_3_int
"""


class SymtabTest(unittest.TestCase):
    def test_llvm_elf(self):
        syms = ld.parse_symtab(SYMTAB_LLVM.splitlines(), "elf")
        self.assertEqual([(s.addr, s.name, s.section) for s in syms],
                         [(0x193a8, "Lbn_F1_4_main1_1_f__if.then.1", ".text"),
                          (0x19380, "bn_F1_4_main1_1_f", ".text"),
                          (0x89bd0, "__handle.bn_F1_4_main1_1_f", ".data.rel.ro")])
        self.assertTrue(syms[1].is_func and not syms[1].is_local)
        self.assertTrue(syms[0].is_local and not syms[0].is_func)

    def test_gnu(self):
        syms = ld.parse_symtab(SYMTAB_GNU.splitlines(), "elf")
        self.assertEqual([s.name for s in syms], ["bn_F1_4_main1_1_f", "helper"])

    def test_macho_strips_prefix(self):
        syms = ld.parse_symtab(SYMTAB_MACHO.splitlines(), "macho")
        self.assertEqual([(s.name, s.section, s.is_func) for s in syms],
                         [("main", "__TEXT,__text", True),
                          ("bn_F1_4_main1_1_f", "__TEXT,__text", True),
                          ("__typeinfo_name.bn_S0_1_3_int", "__TEXT,__const", False)])

    def test_roles(self):
        def sym(name, flags):
            return ld.Sym(0, name, ".text", flags)
        funcs = {"f", "bn_F1_1_p1_3_a__b"}
        cases = [("f", "g     F", True, ld.FUNC), ("Lf__b", "l       ", True, ld.LABEL),
                 ("Lbn_F1_1_p1_3_a__b__for.cond.1", "l       ", True, ld.LABEL),
                 ("$a", "l       ", True, ld.MAPC), ("$x.12", "l       ", True, ld.MAPC),
                 ("$d", "l       ", True, ld.MAPD), ("lstr_0", "l       ", True, ld.OTHER),
                 ("lstr_0", "l       ", False, ld.FUNC),
                 # Local L symbols that do not name a function's block: an
                 # assembly source's labels, data included.
                 ("Lmz_msg", "l       ", True, ld.OTHER), ("Lg__b", "l       ", True, ld.OTHER),
                 ("Lx64rd_12", "l       ", False, ld.OTHER)]
        for name, flags, typed, role in cases:
            with self.subTest(name=name, typed=typed):
                self.assertEqual(ld.sym_role(sym(name, flags), typed, funcs), role)

    def test_func_names(self):
        syms = [ld.Sym(0, n, ".text", fl) for n, fl in
                (("f", "g     F"), ("Lf__b", "l       "), ("o", "l       "), ("$x", "l       "))]
        self.assertEqual(ld.func_names(syms, True), {"f"})
        self.assertEqual(ld.func_names(syms, False), {"f", "o"})

    def test_sections(self):
        llvm = ["Idx Name          Size     VMA              Type",
                " 15 .text         000562ac 0000000000019280 TEXT",
                "  0 __text        0002821c 0000000100000580 TEXT"]
        gnu = [" 14 .text         000562ac  0000000000019280  0000000000019280  00019280  2**6",
               "                  CONTENTS, ALLOC, LOAD, READONLY, CODE"]
        h = ld.parse_sections(llvm)
        self.assertEqual(ld.section_extent(h, ".text"), (0x19280, 0x19280 + 0x562ac))
        self.assertEqual(ld.section_extent(h, "__TEXT,__text"), (0x100000580, 0x10002879C))
        self.assertEqual(h[".text"][2], "TEXT")
        self.assertEqual(ld.parse_sections(gnu)[".text"], (0x19280, 0x562ac, None))
        self.assertIsNone(ld.section_extent(h, ".init"))


class LineTest(unittest.TestCase):
    def test_raw_bytes(self):
        self.assertEqual(ld.raw_bytes("48 89 e5"), b"\x48\x89\xe5")
        self.assertEqual(ld.raw_bytes("d42bdda0"), b"\xa0\xdd\x2b\xd4")
        self.assertEqual(ld.raw_bytes("f2c0 0007"), b"\xc0\xf2\x07\x00")
        self.assertIsNone(ld.raw_bytes(""))
        self.assertIsNone(ld.raw_bytes("xyz"))

    def test_syntaxes(self):
        cases = [
            ("   19380: 55                           \tpushq\t%rbp",
             (0x19380, b"U", "pushq\t%rbp")),
            ("   19380:\t55                   \tpush   %rbp", (0x19380, b"U", "push   %rbp")),
            ("   18e80: d42bdda0     \tbrk\t#0x5eed",
             (0x18E80, b"\xa0\xdd\x2b\xd4", "brk\t#0x5eed")),
            ("   10844: bc a7 06 00  \t.word\t0x0006a7bc",
             (0x10844, b"\xbc\xa7\x06\x00", ".word\t0x0006a7bc")),
            ("100000580:\t3f 00 00 f1\tcmp\tx1, #0x0",
             (0x100000580, b"\x3f\x00\x00\xf1", "cmp\tx1, #0x0")),
            ("10000063c:\t\t.long\t0x4d2e7472", (0x10000063C, None, ".long\t0x4d2e7472")),
            ("   193e9:\tcc cc cc ", (0x193E9, b"\xcc\xcc\xcc", None)),
        ]
        for line, want in cases:
            with self.subTest(line=line):
                self.assertEqual(ld.split_line(line), want)
        for line in ("0000000000019380 <bn_F1_4_main1_1_f>:", "\t...", "_main:",
                     "Disassembly of section .text:", ""):
            self.assertIsNone(ld.split_line(line))

    def test_item_size(self):
        self.assertEqual(ld.item_size(None, ".long\t0x1"), 4)
        self.assertEqual(ld.item_size(None, ".short\t0x1"), 2)
        self.assertEqual(ld.item_size(b"\x90", "nop"), 1)
        self.assertIsNone(ld.item_size(None, "nop"))

    def test_resolve_target(self):
        syms = {"bn_F1_4_main1_1_f": 0x1000}
        cases = [("0x193a8 <Lbn_x__b>", "elf", 0x193A8), ("193a8 <Lbn_x__b>", "elf", 0x193A8),
                 ("x1, 0x100000624", "macho", 0x100000624),
                 ("w8, #0x3f, 0x100000e68", "macho", 0x100000E68),
                 ("_bn_F1_4_main1_1_f", "macho", 0x1000),
                 ("_bn_F1_4_main1_1_f+0x10", "macho", 0x1010),
                 ("_unknown", "macho", None)]
        for text, fmt, want in cases:
            with self.subTest(text=text):
                self.assertEqual(ld.resolve_target(text, fmt, syms), want)


GNU_X86 = """\
Disassembly of section .text:

0000000000001000 <f>:
    1000:\t49 ba cd cc cc cc cc \tmovabs $0xcccccccccccccccd,%r10
    1007:\tcc cc cc
    100a:\te9 01 00 00 00       \tjmp    1010 <g>
\t...
    1010:\tc3                   \tret
"""

MACHO_A64 = """\
fk:
(__TEXT,__text) section
_f:
100000580:\t3f 00 00 f1\tcmp\tx1, #0x0
100000584:\t62 13 00 14\tb\t_g
100000588:\t\t.long\t0x4d2e7472
10000058c:\t00 00 00 00\tudf\t#0x0
_g:
100000590:\tc0 03 5f d6\tret
"""


class DisasmTest(unittest.TestCase):
    def test_gnu_continuation_and_gap(self):
        out = list(ld.parse_disasm(GNU_X86.splitlines(True), layout_x86.decode, "elf", {}))
        self.assertEqual([s for s, _ in out], [".text"] * 4)
        recs = [r for _, r in out]
        self.assertEqual([(r.addr, r.size, r.cls, r.kind) for r in recs],
                         [(0x1000, 10, ld.CODE, None), (0x100A, 5, ld.CODE, "jmp"),
                          (0x100F, 1, ld.GAP, None), (0x1010, 1, ld.CODE, "ret")])
        self.assertEqual(recs[1].tgt, 0x1010)

    def test_macho(self):
        syms = {"f": 0x100000580, "g": 0x100000590}
        recs = [r for s, r in ld.parse_disasm(MACHO_A64.splitlines(True),
                                              layout_arm.decode_aarch64, "macho", syms)]
        self.assertEqual([(r.addr, r.cls, r.kind, r.tgt) for r in recs],
                         [(0x100000580, ld.CODE, None, None),
                          (0x100000584, ld.CODE, "b", 0x100000590),
                          (0x100000588, ld.DATA, None, None),
                          (0x10000058C, ld.GAP, None, None),
                          (0x100000590, ld.CODE, "ret", None)])


if __name__ == "__main__":
    unittest.main()
