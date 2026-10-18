"""Tests for layout_names.py: block labels, which functions receive placement
filler, the mangled-name grammar and the assembly-source scan.

Hand-written names and snippets only.  Nothing runs these automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_names as names

# A name the mangler produces for the destructor of an anonymous struct
# holding a generic instance: its trailing _4_bool lies outside the grammar,
# but it is a compiled function and receives filler.
UNPARSED = ("bn_I3_3_pkg6_binate5_check56___dtor_anon2_92_mp_N4_3_pkg3_std10_containers3_"
            "vec55_Vec1_mN3_3_pkg6_binate5_check12_InstanceBody_4_bool")


class BlockLabelTest(unittest.TestCase):
    def test_block_labels(self):
        funcs = {"f", "bn_F1_4_main1_15___dtor_ms_uint8", "g"}
        for name in ("Lf__b", "Lbn_F1_4_main1_15___dtor_ms_uint8__if.then.1", "Lg__x__y"):
            with self.subTest(name=name):
                self.assertTrue(names.block_label(name, funcs))
        for name in ("Lmz_msg", "Lx64rd_12", "Lh__b", "f__b", "L", "L__b"):
            with self.subTest(name=name):
                self.assertFalse(names.block_label(name, funcs))


class BinateFuncTest(unittest.TestCase):
    def test_parsed(self):
        cases = {
            "bn_F1_4_main1_4_main": "main",
            "bn_F3_3_pkg8_builtins4_lang2_3_int6_String": "pkg/builtins/lang",
            "bn_F1_4_main1_15___dtor_ms_uint8": "main",
            "bn_I3_3_pkg4_stdx6_slices6_Append1_mN3_3_pkg6_binate5_check5_Scope":
                "pkg/stdx/slices",
            "bn_I4_3_pkg3_std10_containers3_vec12___dtor_44Vec1_mN3_3_pkg6_binate3_ast4_Expr":
                "pkg/std/containers/vec",
            "bn_I1_1_p1_g2_fp1_N0_3_intr0_a4_N0_5_uint8": "p",
            "bn_I1_1_p1_g1_S2_1_aN0_3_int1_bN0_4_bool": "p",
            "bn_entry": "main", "bn_init": "main",
        }
        for name, pkg in cases.items():
            with self.subTest(name=name):
                self.assertEqual(names.binate_func(name), pkg)
                self.assertTrue(names.placed(name))

    def test_not_parsed(self):
        for name in ("bn_F1_4_main1_4_main__shim", "bn_F1_4_main1_4_main__shimP",
                     "bn_F1_4_main1_4_main__vt", "bn_F3_3_pkg8_builtins7_reflect1_9___Package",
                     "bn_G1_4_main1_1_x", "bn_S1_4_main1_1_T", "__centry.bn_F1_4_main1_1_f",
                     "bn_F1_4_main1_9_f", "bn_F01_4_main1_1_f", "bn_I1_1_p1_g1_Q", "main",
                     "Lbn_F1_4_main1_1_f__b", "bn_F", UNPARSED):
            with self.subTest(name=name):
                self.assertIsNone(names.binate_func(name))

    def test_placed_needs_no_parse(self):
        # Filler is keyed by the symbol, so a compiled function is placed
        # whether or not its name parses; the synthesized shims and the
        # package descriptor are not, and nor is anything not bn_F / bn_I.
        for name in (UNPARSED, "bn_F1_4_main1_9_f", "bn_I1_1_p1_g1_Q"):
            with self.subTest(name=name):
                self.assertTrue(names.placed(name))
        for name in ("bn_F1_4_main1_4_main__shim", "bn_F1_4_main1_4_main__shimP",
                     UNPARSED + "__shim", UNPARSED + "__shimP",
                     "bn_F3_3_pkg8_builtins7_reflect1_9___Package", "bn_G1_4_main1_1_x",
                     "__centry.bn_F1_4_main1_1_f", "main", "Lbn_F1_4_main1_1_f__b"):
            with self.subTest(name=name):
                self.assertFalse(names.placed(name))


ASM = """\
// #[build(is(arch, "aarch64"))]
.global_c bn_F3_3_pkg8_builtins2_rt1_7_MemZero
\t.global bn_entry
bn_F3_3_pkg8_builtins2_rt1_7_MemZero:
Lmz_a16:
\tret
"""


class AsmTest(unittest.TestCase):
    def test_defined_globals_only(self):
        lines = ASM.splitlines(True)
        self.assertEqual(names.asm_defined(lines, "aarch64"),
                         {"bn_F3_3_pkg8_builtins2_rt1_7_MemZero"})
        self.assertEqual(names.asm_defined(lines), {"bn_F3_3_pkg8_builtins2_rt1_7_MemZero"})

    def test_build_constraint(self):
        lines = ASM.splitlines(True)
        self.assertEqual(names.asm_defined(lines, "x86_64"), set())
        neg = ['// #[build(not(is(arch, "aarch64")))]\n'] + lines[1:]
        self.assertEqual(len(names.asm_defined(neg, "aarch64")), 1)


if __name__ == "__main__":
    unittest.main()
