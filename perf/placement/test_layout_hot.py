"""Tests for layout_hot.py (--hot): parsing `perf report --stdio` text and
crediting its rows, block labels and bare addresses included, to functions
and loops of the x86-64 fixture program from layout_testutil.py.

No binaries, disassemblers or perf are needed.  Nothing runs these
automatically:

  python3 -m unittest discover perf/placement
"""

import unittest

import layout_hot as lh
import layout_report as rep
import layout_testutil as tu
from test_layout import load

BODY = "Lbn_F1_4_main1_2_f1__for.body.2"
EXIT = "Lbn_F1_4_main1_2_f1__for.exit.3"

# perf names blocks by their labels, as it does on a native-backend binary.
PERF = """\
# Samples: 41K of event 'cpu-clock:pppH'
#
# Overhead  Command  Shared Object      Symbol
# ........  .......  .................  ..............................
#
    20.00%  prog     prog               [.] {loop}
    10.00%  prog     prog               [.] {f1}
     5.00%  prog     prog               [.] {body}
     3.21%  prog     [kernel.kallsyms]  [k] clear_page_erms
     2.00%  prog     libc.so.6          [.] memcpy
     1.00%  prog     prog               [.] {exit}
            |
            ---{f1}
     0.50%  prog     prog               [.] 0x0000000000001042
     0.30%  prog     prog               [.] not_in_this_binary
     0.25%  prog     prog               [.] cexp
""".format(loop=tu.LOOP, f1=tu.F1, body=BODY, exit=EXIT)

PERF_CHILDREN = """\
# Children      Self  Command  Shared Object  Symbol
    90.00%    10.00%  prog     prog           [.] bn_F1_4_main1_2_f2
    80.00%     0.00%  prog     prog           [.] bn_F1_4_main1_2_f1
"""

PERF_SYM_ONLY = """\
# Overhead  Symbol
    60.00%  [.] bn_F1_4_main1_2_f2
    40.00%  [.] memcpy
"""

# `perf record -e cycles:u,instructions:u` reported without --group: one
# table per event, each adding up to 100%.
PERF_TWO_EVENTS = """\
# Samples: 1K of event 'cycles:u'
# Overhead  Command  Shared Object  Symbol
    70.00%  prog     prog           [.] bn_F1_4_main1_2_f1
    30.00%  prog     prog           [.] bn_F1_4_main1_2_f2
#
# Samples: 1K of event 'instructions:u'
# Overhead  Command  Shared Object  Symbol
    90.00%  prog     prog           [.] bn_F1_4_main1_2_f1
    10.00%  prog     prog           [.] bn_F1_4_main1_2_f2
"""

# `perf report --stdio -F sym,overhead`: no row in the layout parse_perf reads.
PERF_OTHER_ORDER = """\
# Symbol                          Overhead
  [.] bn_F1_4_main1_2_f1            70.00%
"""


def parse(text):
    return lh.parse_perf(text.splitlines(True))[0]


class ParseTest(unittest.TestCase):
    def test_overhead_column(self):
        rows, event = lh.parse_perf(PERF.splitlines(True))
        self.assertEqual(event, "cpu-clock:pppH")
        self.assertEqual(len(rows), 8)
        self.assertEqual(rows[0], lh.Row(20.0, "prog", tu.LOOP))
        self.assertNotIn("clear_page_erms", [r.sym for r in rows])
        self.assertIn(lh.Row(2.0, "libc.so.6", "memcpy"), rows)

    def test_self_column(self):
        rows = parse(PERF_CHILDREN)
        self.assertEqual([(r.pct, r.sym) for r in rows],
                         [(10.0, "bn_F1_4_main1_2_f2"), (0.0, "bn_F1_4_main1_2_f1")])

    def test_no_dso_column(self):
        rows, event = lh.parse_perf(PERF_SYM_ONLY.splitlines(True))
        self.assertEqual(rows, [lh.Row(60.0, None, "bn_F1_4_main1_2_f2"),
                                lh.Row(40.0, None, "memcpy")])
        self.assertIsNone(event)

    def test_first_event_only(self):
        rows, event = lh.parse_perf(PERF_TWO_EVENTS.splitlines(True))
        self.assertEqual([(r.pct, r.sym) for r in rows],
                         [(70.0, "bn_F1_4_main1_2_f1"), (30.0, "bn_F1_4_main1_2_f2")])
        self.assertEqual(event, "cycles:u, the first of 2 events")

    def test_unrecognized_report_is_an_error(self):
        for text in (PERF_OTHER_ORDER, "", "# only a header\n"):
            with self.subTest(text=text):
                with self.assertRaisesRegex(ValueError, "perf.txt: no sample row"):
                    lh.parse_perf(text.splitlines(True), "perf.txt")


class ApplyTest(unittest.TestCase):
    def setUp(self):
        self.lay = load(tu.x86_program(7))
        self.funcs = {f.name: f for f in self.lay.funcs}

    def test_labels_and_addresses_credit_function_and_loop(self):
        totals = lh.apply_hot(self.lay, parse(PERF))
        f1 = self.funcs[tu.F1]
        self.assertAlmostEqual(f1.hot, 20 + 10 + 5 + 1 + 0.5)
        (loop,) = f1.loops
        self.assertAlmostEqual(loop["hot"], 20 + 5 + 0.5)
        self.assertAlmostEqual(self.funcs["cexp"].hot, 0.25)
        self.assertIsNone(self.funcs[tu.F2].hot)
        self.assertEqual(totals, {"credited": 36.75, "ambiguous": 0.0, "unmatched": 0.3,
                                  "other_dso": 2.0})

    def test_other_files_count_when_none_is_the_binary(self):
        totals = lh.apply_hot(self.lay, parse(PERF_SYM_ONLY))
        self.assertAlmostEqual(self.funcs[tu.F2].hot, 60.0)
        self.assertEqual((totals["unmatched"], totals["other_dso"]), (40.0, 0.0))

    def test_ambiguous_local_label(self):
        p = tu.Prog("x86_64", 0x1000)
        p.sym("f")
        p.label("Ltmp_1")
        p.op(b"\xc3", "retq")
        p.sym("g")
        p.label("Ltmp_1")
        p.op(b"\xc3", "retq")
        lay = load(p)
        totals = lh.apply_hot(lay, [lh.Row(7.0, None, "Ltmp_1")])
        self.assertEqual(totals["ambiguous"], 7.0)
        self.assertTrue(all(f.hot is None for f in lay.funcs))

    def test_rows_sorted_by_overhead(self):
        self.lay.hot = dict(lh.apply_hot(self.lay, parse(PERF)),
                            file="perf.txt")
        rows = rep.func_rows(self.lay, [])
        self.assertEqual([(r["name"], r["hot"]) for r in rows[:2]],
                         [(tu.F1, 36.5), ("cexp", 0.25)])
        self.assertIsNone(rows[2]["hot"])
        (loop,) = rep.loop_rows(self.lay, [])
        self.assertEqual(loop["hot"], 25.5)
        self.assertNotIn("_iv", loop)
        self.assertEqual(rep.summary(self.lay)["hot"]["credited"], 36.75)

    def test_no_hot_column_without_hot(self):
        self.assertNotIn("hot", rep.func_rows(self.lay, [])[0])
        self.assertNotIn("hot", rep.loop_rows(self.lay, [])[0])


if __name__ == "__main__":
    unittest.main()
