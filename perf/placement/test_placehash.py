"""Tests for placehash.py, the Python twin of the native backends' placement.

The pinned vectors are the same as pkg/binate/native/place/place_test.bn pins
for place.PlaceHash / place.PlaceFillBefore.  Only the Binate tests run with
the unit-test suite; nothing runs these automatically, so run them whenever
either implementation or either set of vectors changes:

  python3 -m unittest discover perf/placement
"""

import unittest

import placehash as ph

FOO = "bn_F1_4_main1_3_foo"
MAIN = "bn_F1_4_main1_4_main"


class PlaceHashTest(unittest.TestCase):
    def test_pinned_vectors(self):
        vectors = [
            (0, "", 0xAB3E7C0B),
            (1, "", 0x4A216C31),
            (0, "a", 0x1A80B1B3),
            (1, "a", 0x1156BD31),
            (7, "hello world", 0x214B4E12),
            (12345, FOO, 0xE67F5803),
            (2147483647, MAIN, 0xEE674A5E),
            (-1, "x", 0x5E4EB042),
        ]
        for seed, key, want in vectors:
            with self.subTest(seed=seed, key=key):
                self.assertEqual(ph.place_hash(seed, key), want)

    def test_bytes_and_str_keys_agree(self):
        self.assertEqual(ph.place_hash(9, MAIN), ph.place_hash(9, MAIN.encode()))


class FillBeforeTest(unittest.TestCase):
    def test_pinned_vectors(self):
        vectors = [
            (12345, "shift", FOO, 16, 0, 48),
            (12345, "phase", FOO, 16, 5, 32),
            (12345, "phase", FOO, 16, 100, 0),
            (12345, "shift", FOO, 4, 100, 12),
            (12345, "phase", FOO, 4, 100, 40),
            (7, "phase", MAIN, 4, 0, 60),
            (7, "shift", MAIN, 4, 100, 60),
            (42, "phase", "main.alpha", 16, 3, 32),
            (2147483647, "phase", MAIN, 4, 64, 56),
            (0, "phase", "x", 16, 5, 0),
        ]
        for seed, mode, sym, unit, off, want in vectors:
            with self.subTest(seed=seed, mode=mode, sym=sym, unit=unit, off=off):
                self.assertEqual(ph.fill_before(seed, mode, sym, unit, off), want)

    def test_mode_constants_match_names(self):
        self.assertEqual(ph.fill_before(7, ph.PLACE_SHIFT, MAIN, 4, 100),
                         ph.fill_before(7, "shift", MAIN, 4, 100))
        self.assertEqual(ph.fill_before(7, ph.PLACE_PHASE, MAIN, 4, 100),
                         ph.fill_before(7, "phase", MAIN, 4, 100))

    def test_mode_changes_the_fill(self):
        # Computed from the pinned hash of FOO under seed 12345, at offsets where
        # the modes disagree: shift ignores the offset, phase compensates for it.
        h = 0xE67F5803
        self.assertEqual(ph.place_hash(12345, FOO), h)
        for unit, off in ((4, 100), (16, 5), (4, 37), (16, 100)):
            shift = unit * (h % (ph.PLACE_SPAN // unit))
            phase = (shift - (off + unit - 1) // unit * unit) % ph.PLACE_SPAN
            self.assertNotEqual(shift, phase)
            self.assertEqual(ph.fill_before(12345, "shift", FOO, unit, off), shift)
            self.assertEqual(ph.fill_before(12345, "phase", FOO, unit, off), phase)

    def test_rejects_unknown_mode(self):
        for mode in ("jitter", "", "Phase", 2, -1, None):
            with self.subTest(mode=mode):
                with self.assertRaises(ValueError):
                    ph.fill_before(7, mode, MAIN, 4, 0)
        # Also with seed 0, which places nothing.
        with self.assertRaises(ValueError):
            ph.fill_before(0, "jitter", MAIN, 4, 0)

    def test_rejects_seed_out_of_range(self):
        for seed in (-1, ph.PLACE_SEED_MAX + 1, 2**32):
            with self.subTest(seed=seed):
                with self.assertRaises(ValueError):
                    ph.fill_before(seed, "phase", MAIN, 4, 0)
                with self.assertRaises(ValueError):
                    ph.entry_phase(seed, MAIN, 4)
        self.assertEqual(ph.fill_before(ph.PLACE_SEED_MAX, "phase", MAIN, 4, 64), 56)
        self.assertGreaterEqual(ph.entry_phase(ph.PLACE_SEED_MAX, MAIN, 4), 0)

    def test_rejects_bad_unit(self):
        for unit in (0, -4, 24, 128):
            with self.subTest(unit=unit):
                with self.assertRaises(ValueError):
                    ph.fill_before(7, "phase", MAIN, unit, 0)
                with self.assertRaises(ValueError):
                    ph.entry_phase(7, MAIN, unit)

    def test_phase_mode_reaches_entry_phase(self):
        for unit in (4, 16):
            for i in range(64):
                sym = "sym%d" % i
                phi = ph.entry_phase(31337, sym, unit)
                for off in range(0, 131, 3):
                    fill = ph.fill_before(31337, "phase", sym, unit, off)
                    self.assertTrue(0 <= fill < ph.PLACE_SPAN and fill % unit == 0)
                    aligned = (off + unit - 1) // unit * unit
                    self.assertEqual((aligned + fill) % ph.PLACE_SPAN, phi)


class FillInsnTest(unittest.TestCase):
    def test_units(self):
        self.assertEqual(ph.UNIT, {"x86_64": 16, "aarch64": 4, "arm32": 4})

    def test_filler_encodings(self):
        # INT3; BRK #0x5EED; BKPT #0x5EED (as the Binate emitter tests pin them).
        self.assertEqual(ph.FILL_INSN["x86_64"], b"\xcc")
        self.assertEqual(int.from_bytes(ph.FILL_INSN["aarch64"], "little"), 0xD42BDDA0)
        self.assertEqual(int.from_bytes(ph.FILL_INSN["arm32"], "little"), 0xE125EE7D)


class DriverSeedTest(unittest.TestCase):
    def test_stack_pad(self):
        pads = [ph.stack_pad(s) for s in range(1, 501)]
        for p in pads:
            self.assertTrue(0 <= p < 4096 and p % 16 == 0)
        self.assertGreater(len(set(pads)), 100)

    def test_salted_seed(self):
        for s in list(range(0, 300)) + [ph.PLACE_SEED_MAX]:
            salted = ph.salted_seed(s)
            self.assertTrue(1 <= salted <= ph.PLACE_SEED_MAX)
            self.assertNotEqual(salted, s)
        self.assertEqual(ph.salted_seed(5), ph.salted_seed(5))


if __name__ == "__main__":
    unittest.main()
