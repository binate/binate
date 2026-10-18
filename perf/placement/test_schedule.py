"""Tests for schedule.py, the run order of placement A/B rounds.

Nothing runs these automatically:
  python3 -m unittest discover perf/placement
"""

import unittest
from collections import Counter

import schedule as sch


def naive_rotation(r, k):
    """An order once considered: the arms rotated by r, reversed on odd r."""
    row = [(i + r) % k for i in range(k)]
    return row[::-1] if r % 2 else row


class WilliamsTest(unittest.TestCase):
    def test_rows_are_permutations(self):
        for k in range(1, 9):
            rows = sch.williams(k)
            self.assertEqual(len(rows), sch.cycle(k))
            for row in rows:
                self.assertEqual(sorted(row), list(range(k)))

    def test_positions_balanced_over_a_cycle(self):
        for k in range(2, 6):
            with self.subTest(k=k):
                rows = sch.williams(k)
                count = Counter((arm, pos) for row in rows for pos, arm in enumerate(row))
                self.assertEqual(set(count.values()), {len(rows) // k})
                self.assertEqual(len(count), k * k)

    def test_neighbour_pairs_balanced_over_a_cycle(self):
        for k in range(2, 6):
            with self.subTest(k=k):
                rows = sch.williams(k)
                pairs = Counter((row[i], row[i + 1]) for row in rows for i in range(k - 1))
                self.assertEqual(len(pairs), k * (k - 1))
                self.assertEqual(len(set(pairs.values())), 1)

    def test_known_squares(self):
        self.assertEqual(sch.williams(2), [[0, 1], [1, 0]])
        self.assertEqual(sch.williams(4)[0], [0, 1, 3, 2])
        self.assertEqual(sch.williams(3)[:3], [[0, 1, 2], [1, 2, 0], [2, 0, 1]])
        self.assertEqual(sch.williams(3)[3:], [[2, 1, 0], [0, 2, 1], [1, 0, 2]])
        self.assertEqual(sch.williams(1), [[0]])

    def test_bad_arguments(self):
        with self.assertRaises(ValueError):
            sch.williams(0)
        with self.assertRaises(ValueError):
            sch.round_orders(0, 2, 0)


class RoundOrderTest(unittest.TestCase):
    def test_round_uses_row_mod_cycle(self):
        for k in range(1, 6):
            rows = sch.williams(k)
            for r in range(3 * sch.cycle(k)):
                self.assertEqual(sch.round_orders(r, k, 1)[0], rows[r % len(rows)])

    def test_mirrored_replicates(self):
        for k in range(2, 6):
            for reps in (2, 4):
                for r in range(sch.cycle(k)):
                    orders = sch.round_orders(r, k, reps)
                    for i in range(1, reps):
                        self.assertEqual(orders[i], orders[i - 1][::-1])

    def test_even_replicates_cancel_linear_drift(self):
        # Every arm's mean slot in the round is the same, so a drift that is
        # linear in the slot adds the same to every arm.
        for k in range(2, 6):
            for reps in (2, 4):
                orders = sch.round_orders(1, k, reps)
                slots = Counter()
                for rep, order in enumerate(orders):
                    for pos, arm in enumerate(order):
                        slots[arm] += rep * k + pos
                self.assertEqual(len(set(slots.values())), 1, (k, reps, slots))

    def test_odd_replicates_do_not_cancel_drift(self):
        orders = sch.round_orders(0, 2, 3)
        slots = Counter()
        for rep, order in enumerate(orders):
            for pos, arm in enumerate(order):
                slots[arm] += rep * 2 + pos
        self.assertNotEqual(slots[0], slots[1])

    def test_plan_lists_every_run_in_order(self):
        p = sch.plan([5, 9], 3, 2)
        self.assertEqual(len(p), 2 * 2 * 3)
        self.assertEqual(p[0], (0, 5, 0, 0, 0))
        self.assertEqual([x[4] for x in p[:6]], [0, 1, 2, 2, 1, 0])
        self.assertEqual({x[1] for x in p[6:]}, {9})


class NaiveRotationRegressionTest(unittest.TestCase):
    def test_rotation_with_odd_reversal_degenerates_for_two_arms(self):
        # Rotating by r and reversing on odd r gives [0, 1] in every round
        # for k = 2: arm 0 would always run first.
        firsts = Counter(naive_rotation(r, 2)[0] for r in range(10))
        self.assertEqual(firsts, Counter({0: 10}))
        balanced = Counter(sch.round_orders(r, 2, 1)[0][0] for r in range(10))
        self.assertEqual(balanced, Counter({0: 5, 1: 5}))


if __name__ == "__main__":
    unittest.main()
