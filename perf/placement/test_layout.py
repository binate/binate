"""Tests for layout.py's core on the x86-64 fixture program from
layout_testutil.py and small hand-built programs: function extents and
trailing material, block labels and data in code, executed NOPs, erratum
windows, --compare (loop matching included), the output formats and the
CLI.  The --expect-seed tests are in test_layout_seed.py.

No binaries or disassemblers are needed.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import argparse
import io
import json
import os
import tempfile
import unittest
import unittest.mock

import layout
import layout_report as rep
import layout_testutil as tu
from layout_disasm import DATA, FILL, PAD


def load(prog, style="llvm", loops=True, window=None, fmt=None, asm=frozenset()):
    lay = layout.Layout(prog.arch, fmt or ("macho" if style == "macho" else "elf"),
                        window, 64, loops, "prog", asm)
    return lay.load(prog.symtab(style).splitlines(True), prog.disasm(style).splitlines(True),
                    prog.headers(style))


def by_name(lay):
    return {f.name: f for f in lay.funcs}


class CoreTest(unittest.TestCase):
    def setUp(self):
        self.prog = tu.x86_program(7)
        self.lay = load(self.prog)
        self.f = by_name(self.lay)

    def test_functions_and_labels(self):
        self.assertEqual([f.name for f in self.lay.funcs],
                         [tu.F1, tu.F2, "cexp", tu.F3, tu.PKG_A, tu.G1, tu.G2, tu.PKG_B,
                          "helper"])
        self.assertNotIn(tu.LOOP, self.f)
        self.assertEqual([f.pkg for f in self.lay.funcs],
                         ["main", "main", None, "main", None, "p", "p", None, None])

    def test_extents_stop_before_filler_and_pad(self):
        f1 = self.f[tu.F1]
        self.assertEqual((f1.addr, f1.size, f1.span_end), (0x1030, 41, 0x1070))
        self.assertEqual(f1.insns, 10)
        self.assertEqual(self.f["cexp"].size, 8)
        self.assertEqual(self.f["helper"].size, 2)

    def test_whole_binary_bytes(self):
        b = self.lay.bytes
        fills = sum(len(raw) for _, raw, text, _, _ in self.prog.items if text == "int3")
        self.assertEqual(b["fill"], fills)
        self.assertEqual(sum(b.values()), self.prog.pc - 0x1000)
        s = rep.summary(self.lay)
        self.assertEqual(s["text_bytes"], self.prog.pc - 0x1000)
        self.assertEqual(s["branches"]["total"], sum(f.br for f in self.lay.funcs))
        self.assertEqual(s["branches"]["jcc"], 2)
        self.assertEqual(s["functions"], 9)
        self.assertEqual(s["binate_functions"], 5)
        self.assertEqual(s["erratum"]["units"], s["branches"]["total"])

    def test_loop(self):
        (lp,) = self.f[tu.F1].loops
        self.assertEqual((lp["header"], lp["label"], lp["depth"], lp["innermost"]),
                         (0x1040, tu.LOOP, 1, True))
        self.assertEqual((lp["blocks"], lp["bytes"], lp["pad"], lp["pad_ft"]), (2, 18, 7, False))

    def test_start_histogram_uses_first_entries(self):
        hist = rep.summary(self.lay)["start_mod_64"]
        self.assertEqual(sum(v[0] for v in hist.values()), 5)
        cexp = self.f["cexp"].addr % 64
        self.assertGreaterEqual(hist[cexp][0], 1)

    def test_unreachable_code_is_not_attributed(self):
        p = tu.Prog("x86_64", 0x1000)
        p.sym("f")
        p.op(b"\x55", "pushq\t%rbp")
        p.op(b"\xc3", "retq")
        p.label("Lf__dead.1")
        p.op(b"\x5d", "popq\t%rbp")
        p.op(b"\xc3", "retq")
        p.nops_to(16)
        loop = p.pc
        p.op(b"\x48\xff\xc8", "decq\t%rax")
        p.op(b"\x75\xfb", "jne\t{t}", loop)
        p.op(b"\xc3", "retq")
        p.nops_to(16)
        p.sym("g")
        p.op(b"\xc3", "retq")
        lay = load(p)
        f = by_name(lay)["f"]
        self.assertEqual((f.size, f.insns, f.loops), (4, 4, []))
        self.assertEqual(lay.unnamed, 6)
        self.assertEqual(lay.bytes["code"], 4 + 6 + 1)

    def test_symbol_at_function_start_is_a_label(self):
        p = tu.Prog("arm32", 0x2000)
        p.sym("f")
        p.sym("f_alias_data", "l      ")
        p.op(0xE12FFF1E, "bx\tlr")
        lay = load(p)
        self.assertEqual((lay.funcs[0].size, lay.funcs[0].cut), (4, False))

    def test_section_end_zeros_count_as_gap(self):
        p = tu.Prog("x86_64", 0x1000)
        p.sym("f")
        p.op(b"\xc3", "retq")
        p.skip(15)
        lay = load(p)
        self.assertEqual((lay.bytes["code"], lay.bytes["gap"]), (1, 15))
        self.assertEqual(rep.summary(lay)["text_bytes"], 16)

    def test_no_pad_means_no_pad_ft(self):
        p = tu.Prog("aarch64", 0x1000)
        p.sym("f")
        head = p.pc
        p.op(0xD1000421, "sub\tx1, x1, #0x1")
        p.op(0xB5FFFFE1, "cbnz\tx1, {t}", head)
        p.op(0xD65F03C0, "ret")
        (lp,) = load(p).funcs[0].loops
        self.assertEqual((lp["pad"], lp["pad_ft"]), (0, None))

    def test_no_symbols(self):
        p = tu.Prog("aarch64", 0x1000)
        p.op(0xD65F03C0, "ret")
        lay = layout.Layout("aarch64", "macho", path="bin")
        lay.load([], p.disasm("macho").splitlines(True), [])
        with self.assertRaisesRegex(RuntimeError, "defines no symbols at all.*no sections"):
            layout.require_functions(lay)

    def test_asm_defined_binate_function_is_not_placed(self):
        lay = load(self.prog, asm=frozenset({tu.F2}))
        self.assertFalse(by_name(lay)[tu.F2].placed)
        self.assertNotIn(tu.F2, [r["name"] for r in lay.expect_seed(7, "phase")])

    def test_data_label_in_asm_code(self):
        # An assembly function ends with a branch and then a string under a
        # local label (Lmsg) that is no block label: the string is data, not
        # code, and the data stops before the next object's gap and filler.
        for mode, seed in (("shift", 11), ("phase", 7)):
            p = tu.Prog("aarch64", 0x1000)
            p.sym("asmfunc")
            p.op(0xF100003F, "cmp\tx1, #0x0")
            p.op(0x14000000, "b\t{t}", 0x1000)
            p.label("Lmsg")
            p.op(0x4D2E7472, "<unknown>")
            p.op(0x655A6D65, "fcmeq\tp5.h, p3/z, z11.h, z26.h")
            p.start_object(64)
            p.placed("bn_F1_4_main1_3_foo", seed, mode)
            p.sym("bn_F1_4_main1_3_foo")
            p.op(0xD65F03C0, "ret")
            lay = load(p)
            f = by_name(lay)
            self.assertEqual((f["asmfunc"].size, f["asmfunc"].insns), (8, 2))
            counts = lay.byte_counts()
            filler = tu.placehash.fill_before(seed, mode, "bn_F1_4_main1_3_foo", 4, 0)
            self.assertEqual((counts[DATA], counts[FILL], counts[PAD]), (8, filler, 48))
            (row,) = lay.expect_seed(seed, mode)
            self.assertEqual(row["status"], "ok")

    def test_symbols_outside_their_section_are_ignored(self):
        # Mach-O's __mh_execute_header is typed as a __text function at the
        # segment base, before the section starts.
        p = tu.Prog("aarch64", 0x100000580)
        p.syms.append((0x100000000, "_mh_execute_header", "g     F"))
        p.sym("f")
        p.op(0xD65F03C0, "ret")
        p.sym("empty")
        p.fill(16)
        p.sym("g")
        p.op(0xD65F03C0, "ret")
        lay = load(p, "macho")
        self.assertEqual([f.name for f in lay.funcs], ["f", "empty", "g"])
        rows = {r["name"]: r for r in rep.func_rows(lay, [])}
        self.assertEqual((rows["empty"]["size"], rows["empty"]["windows"],
                          rows["empty"]["lines"]), (0, 0, 0))

    def test_nop_at_block_start_is_code(self):
        # arm32's register move mov r0, r0 is also a NOP encoding; at a branch
        # target it is executed, so it starts the loop header's block.
        p = tu.Prog("arm32", 0x1000)
        p.sym("f")
        p.op(0xE92D4010, "push\t{r4, lr}")
        p.op(0xEA000000, "b\t{t}", 0x1008)
        p.label("Lf__for.cond.1")
        p.op(0xE1A00000, "mov\tr0, r0")
        p.op(0xE354000A, "cmp\tr4, #10")
        p.op(0xBA000000, "blt\t{t}", 0x1018)
        p.op(0xE8BD8010, "pop\t{r4, pc}")
        p.op(0xE2844001, "add\tr4, r4, #1")
        p.op(0xEAFFFFF9, "b\t{t}", 0x1008)
        lay = load(p)
        (lp,) = lay.funcs[0].loops
        self.assertEqual((lay.funcs[0].insns, lay.bytes[PAD]), (8, 0))
        self.assertEqual((lp["header"], lp["blocks"], lp["insns"]), (0x1008, 2, 5))

    def test_erratum_windows_count_units_outside_the_loop(self):
        # The jmp into the loop crosses 0x1020; the header's window
        # 0x1020-0x103f therefore loses the decoded-uop cache, though the
        # loop's own members hold no hit unit.
        p = tu.Prog("x86_64", 0x1000)
        p.sym("f")
        p.op(b"\x48\x85\xff", "testq\t%rdi, %rdi")
        p.op(b"\x74\x22", "je\t{t}", 0x1027)
        for _ in range(8):
            p.op(b"\x48\x89\xe5", "movq\t%rsp, %rbp")
        p.op(b"\xe9\x00\x00\x00\x00", "jmp\t{t}", 0x1022)
        p.label("Lf__for.cond.1")
        p.op(b"\x48\xff\xcf", "decq\t%rdi")
        p.op(b"\x75\xfb", "jne\t{t}", 0x1022)
        p.op(b"\xc3", "retq")
        lay = load(p)
        f = lay.funcs[0]
        (lp,) = f.loops
        self.assertEqual((lp["jcc"], lp["jccw"]), (0, 1))
        self.assertEqual((f.hits, f.jccw), (1, 2))


def args(**kw):
    base = dict(loops=True, json=False, tsv=False, expect_seed=None, mode=None)
    base.update(kw)
    return argparse.Namespace(**base)


class CompareReportTest(unittest.TestCase):
    def test_compare(self):
        a, b = load(tu.x86_program(0)), load(tu.x86_program(7))
        frows, lrows, stats = rep.compare_rows(a, b, [])
        self.assertEqual(stats["matched"], 9)
        self.assertEqual((stats["only_a"], stats["only_b"]), (0, 0))
        f1 = next(r for r in frows if r["name"] == tu.F1)
        self.assertEqual(f1["m64_b"], tu.placehash.entry_phase(7, tu.F1, 16))
        self.assertEqual(f1["dsize"], 0)
        self.assertEqual(f1["dm64"], (f1["addr_b"] - f1["addr_a"]) % 64)
        (loop,) = lrows
        self.assertEqual(loop["loop"], "for.cond.1")
        self.assertEqual(loop["dwindows"], loop["windows_b"] - loop["windows_a"])

    def test_formats(self):
        lay = load(tu.x86_program(7))
        other = load(tu.x86_program(0))
        rows = lay.expect_seed(7, "phase")
        for kw in ({}, {"json": True}, {"tsv": True}):
            out = io.StringIO()
            rep.emit(lay, other, rows, [], args(expect_seed=7, **kw), out)
            text = out.getvalue()
            self.assertIn(tu.F1, text)
            if kw.get("json"):
                data = json.loads(text)
                self.assertEqual(set(data), {"summary", "functions", "loops", "compare",
                                             "expect_seed"})
                self.assertEqual(data["expect_seed"]["stats"]["failed"], 0)
            elif kw.get("tsv"):
                self.assertIn("# functions\naddr\t", text.replace("name\taddr", "addr"))
                self.assertIn("# expect-seed\n", text)
            else:
                self.assertIn("JCC erratum", text)
                self.assertIn("expect-seed 7 (phase): 5 functions checked, 0 failed", text)

    def test_loops_match_by_key(self):
        # The same two loops in either order: one labeled for.cond.1, one
        # with no label of its own inside block if.merge.2 (an aggregate
        # copy, say).  Each keeps its key, whatever the order.
        f = "bn_F1_4_main1_2_f1"

        def build(order):
            p = tu.Prog("x86_64", 0x1000)
            p.sym(f)
            for part in order:
                if part == "labeled":
                    head = p.label("L%s__for.cond.1" % f)
                    p.op(b"\x48\xff\xcf", "decq\t%rdi")
                else:
                    p.label("L%s__if.merge.2" % f)
                    p.op(b"\x48\x89\xe5", "movq\t%rsp, %rbp")
                    head = p.pc
                    p.op(b"\x48\xff\xce", "decq\t%rsi")
                p.op(b"\x75\xfb", "jne\t{t}", head)
            p.op(b"\xc3", "retq")
            return load(p)
        a, b = build(["labeled", "copy"]), build(["copy", "labeled"])
        self.assertEqual([lp["key"] for lp in a.funcs[0].loops], ["for.cond.1", "if.merge.2#0"])
        _, lrows, stats = rep.compare_rows(a, b, [])
        self.assertEqual(sorted(r["loop"] for r in lrows), ["for.cond.1", "if.merge.2#0"])
        self.assertEqual((stats["loops_only_a"], stats["loops_only_b"]), (0, 0))
        self.assertTrue(all("jccw_a" in r for r in lrows))

    def test_tsv_carries_compare_and_seed_stats(self):
        lay, other = load(tu.x86_program(7)), load(tu.x86_program(0))
        out = io.StringIO()
        rep.emit(lay, other, lay.expect_seed(7, "phase"), [],
                 args(expect_seed=7, mode="phase", tsv=True), out)
        text = out.getvalue()
        self.assertIn("# compare\nkey\tvalue\nbinary\tprog\n", text)
        for line in ("only_a\t0", "only_b\t0", "loops_only_a\t0", "phase_changed\t"):
            self.assertIn("\n" + line, text)
        self.assertIn("# expect-seed-stats\nkey\tvalue\nseed\t7\nmode\tphase\nchecked\t5\n"
                      "failed\t0\n", text)

    def test_func_filter(self):
        lay = load(tu.x86_program(7))
        pats = [layout.re.compile("main1_2_f[12]$")]
        self.assertEqual([r["name"] for r in rep.func_rows(lay, pats)], [tu.F1, tu.F2])
        self.assertEqual(len(rep.loop_rows(lay, pats)), 1)


class CliTest(unittest.TestCase):
    def check_error(self, argv):
        with self.assertRaises(SystemExit) as cm, unittest.mock.patch("sys.stderr",
                                                                      io.StringIO()):
            layout.main(argv)
        self.assertEqual(cm.exception.code, 2)

    def test_argument_errors(self):
        self.check_error(["bin", "--mode", "phase"])
        self.check_error(["bin", "--expect-seed", "-1"])
        self.check_error(["bin", "--window", "24"])
        self.check_error(["bin", "--line", "2"])
        self.check_error(["bin", "--tsv", "--json"])
        self.check_error(["bin", "--arch", "mips"])
        self.check_error(["bin", "--func", "("])

    def test_missing_binary(self):
        with unittest.mock.patch("sys.stderr", io.StringIO()) as err:
            self.assertEqual(layout.main(["/nonexistent/bin"]), 2)
        self.assertIn("layout.py:", err.getvalue())

    def run_main(self, argv, analyze):
        with unittest.mock.patch("layout.analyze", analyze), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as out, \
                unittest.mock.patch("sys.stderr", io.StringIO()) as err:
            code = layout.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_truncated_binary(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "trunc.elf")
            with open(path, "wb") as fh:
                fh.write(b"\x7fELF\x02\x01\x01\x00")
            code, _, err = self.run_main([path], layout.analyze)
        self.assertEqual(code, 2)
        self.assertIn("%s: truncated ELF header" % path, err)

    def test_compare_other_arch(self):
        # OTHER is analyzed as what its own header says, so mixing
        # architectures is refused rather than decoded with the wrong rules.
        def fake(path, arch=None, *rest):
            prog = tu.x86_program(0)
            if path == "arm" and arch is None:
                prog = tu.Prog("arm32", 0x1000)
                prog.sym("f")
                prog.op(0xE12FFF1E, "bx\tlr")
            return load(prog)
        code, _, err = self.run_main(["x86", "--compare", "arm"], fake)
        self.assertEqual(code, 2)
        self.assertIn("cannot compare x86_64 with arm32", err)

    def test_expect_seed_with_nothing_to_check_fails(self):
        def fake(path, *rest):
            p = tu.Prog("x86_64", 0x1000)
            p.sym("main")
            p.op(b"\xc3", "retq")
            return load(p)
        code, out, _ = self.run_main(["cprog", "--expect-seed", "7"], fake)
        self.assertEqual(code, 1)
        self.assertIn("no function that receives placement filler", out)
        self.assertEqual(self.run_main(["cprog"], fake)[0], 0)


if __name__ == "__main__":
    unittest.main()
