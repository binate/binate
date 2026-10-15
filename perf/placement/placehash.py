"""Python twin of the native backends' function-placement filler.

bnc's -fnative-place-seed=S / -fnative-place-mode=M put trap-instruction filler
before each Binate function (pkg/binate/native/place: place.bni specifies the
formulas, place/place.bn implements them).  This module reproduces those
placements exactly, so measurement tools can predict and check where every
function lands without running the compiler:

  place_hash(seed, key)                      place.PlaceHash
  fill_before(seed, mode, sym, unit, off)    place.PlaceFillBefore (+ PlaceCheck)
  entry_phase(seed, sym, unit)               the phase phase mode gives sym

The hash key is a function's mangled symbol without an object-format prefix,
but what the filler positions is the function's FIRST entry point: its first
#[c_export] alias when it has one (a C-entry normalization may sit between the
alias and the mangled symbol), the mangled symbol otherwise.  So check
entry_phase against the address of that first entry, not of the mangled
symbol.

On Mach-O the object divides into per-symbol atoms and bnc links with
-dead_strip, so the filler before an object's first function (and after any
function the link strips) may be discarded.  Phase mode is unaffected, since
.text is aligned to PLACE_SPAN and the linker keeps each atom's address modulo
it; but shift-mode offsets on Mach-O are not exact.

Keep this module in step with place.bn: test_placehash.py and
pkg/binate/native/place/place_test.bn pin the same vectors, but nothing runs
these Python tests automatically, so run
`python3 -m unittest discover perf/placement` when changing either side.

It also derives the per-seed quantities a timing driver needs: the stack pad
that moves the initial stack by a seed-chosen multiple of 16 bytes
(stack_pad), and a second seed for A/A runs whose arms must be placed
differently (salted_seed).

Python standard library only.
"""

MASK32 = 0xFFFFFFFF

# The byte period placement works modulo (place.PLACE_SPAN).
PLACE_SPAN = 64

# Placement modes (place.PLACE_SHIFT / place.PLACE_PHASE), by their
# -fnative-place-mode spelling.
PLACE_SHIFT = 0
PLACE_PHASE = 1
MODES = {"shift": PLACE_SHIFT, "phase": PLACE_PHASE}

# Largest placement seed (place.PLACE_SEED_MAX); bnc accepts 0..PLACE_SEED_MAX.
PLACE_SEED_MAX = 0x7FFFFFFF

# Immediate of the aarch64 BRK / arm32 BKPT filler (place.PLACE_FILL_IMM).
PLACE_FILL_IMM = 0x5EED

# Filler granularity in bytes per architecture (each backend's PlaceUnit).
UNIT = {"x86_64": 16, "aarch64": 4, "arm32": 4}

# One filler instruction per architecture, as little-endian bytes: x86-64 INT3,
# aarch64 BRK #0x5EED, arm32 (A32) BKPT #0x5EED.
FILL_INSN = {
    "x86_64": bytes([0xCC]),
    "aarch64": (0xD4200000 | (PLACE_FILL_IMM << 5)).to_bytes(4, "little"),
    "arm32": (0xE1200070 | ((PLACE_FILL_IMM >> 4) << 8)
              | (PLACE_FILL_IMM & 0xF)).to_bytes(4, "little"),
}


def _key_bytes(key):
    if isinstance(key, str):
        return key.encode("utf-8")
    return bytes(key)


def place_hash(seed, key):
    """place.PlaceHash: FNV-1a-32 of key, XOR uint32(seed) * 0x9E3779B9, then
    murmur3 fmix32; every step wraps modulo 2**32.  Like place.PlaceHash it
    takes any integer seed (wrapped to uint32)."""
    h = 0x811C9DC5
    for b in _key_bytes(key):
        h = ((h ^ b) * 0x01000193) & MASK32
    h ^= (seed * 0x9E3779B9) & MASK32
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & MASK32
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & MASK32
    h ^= h >> 16
    return h


def _check_seed(seed):
    if not 0 <= seed <= PLACE_SEED_MAX:
        raise ValueError("placement seed %r is outside 0..%d" % (seed, PLACE_SEED_MAX))


def _check_unit(unit):
    if unit <= 0 or PLACE_SPAN % unit != 0:
        raise ValueError("filler unit %r does not divide %d" % (unit, PLACE_SPAN))


def _mode_value(mode):
    """mode as PLACE_SHIFT / PLACE_PHASE, from either that value or its name;
    ValueError for anything else, as place.PlaceCheck rejects it."""
    if isinstance(mode, str):
        if mode not in MODES:
            raise ValueError("unknown placement mode %r" % (mode,))
        return MODES[mode]
    if mode not in (PLACE_SHIFT, PLACE_PHASE):
        raise ValueError("unknown placement mode %r" % (mode,))
    return mode


def _align_up(off, unit):
    return (off + unit - 1) // unit * unit


def fill_before(seed, mode, sym, unit, off):
    """place.PlaceFillBefore: the filler bytes emitted before the function
    whose mangled symbol (no object-format prefix) is sym, at .text offset off,
    for filler granularity unit.  mode is PLACE_SHIFT / PLACE_PHASE or its
    name.  Raises ValueError for what place.PlaceCheck rejects: a seed outside
    0..PLACE_SEED_MAX, an unknown mode, or a unit that does not divide
    PLACE_SPAN."""
    _check_seed(seed)
    mode = _mode_value(mode)
    _check_unit(unit)
    if seed == 0:
        return 0
    k = PLACE_SPAN // unit
    phi = unit * (place_hash(seed, sym) % k)
    if mode == PLACE_SHIFT:
        return phi
    return (phi - _align_up(off, unit)) % PLACE_SPAN


def entry_phase(seed, sym, unit):
    """The offset modulo PLACE_SPAN at which phase mode puts the first entry
    point of the function whose mangled symbol is sym (its first #[c_export]
    alias, if it has one).  Meaningful only for a nonzero seed: seed 0 adds no
    filler.  Raises ValueError for a seed outside 0..PLACE_SEED_MAX or a unit
    that does not divide PLACE_SPAN."""
    _check_seed(seed)
    _check_unit(unit)
    return unit * (place_hash(seed, sym) % (PLACE_SPAN // unit))


def stack_pad(seed):
    """Bytes of environment padding for a timed run under seed: a multiple of
    16 in [0, 4096), the same for every arm of the seed's round."""
    return 16 * (place_hash(seed, "stack") % 256)


def salted_seed(seed):
    """A second seed in 1..PLACE_SEED_MAX derived from seed and different
    from it, for A/A runs whose two arms must be placed differently."""
    s = place_hash(seed, "salt") % PLACE_SEED_MAX + 1
    if s == seed:
        s = s % PLACE_SEED_MAX + 1
    return s
