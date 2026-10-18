"""Run order for placement A/B rounds: which arm runs when inside a round.

A round (one placement seed) runs every arm back to back.  The arm order for
round r is row r mod rows of a Williams square over the k arms (k rows for an
even k; for an odd k, 2k rows: the k rows and their reverses).  Over a full
cycle of rows every arm holds every position equally often and every ordered
pair of neighbours occurs equally often, so a position effect, or a carry-over
from the run before (cache, branch-predictor, frequency or page-cache state),
falls on every arm alike instead of on one of them.

Inside a round the replicates alternate between the row and its reverse.  With
an even number of replicates every arm's mean position in time is then the
same, so a drift that is linear over the round cancels out of every arm-to-arm
difference; an odd number leaves part of it.

Python standard library only.  The tests are in test_schedule.py; nothing
runs them automatically:
  python3 -m unittest discover perf/placement
"""


def williams(k):
    """The rows of a Williams square over arms 0..k-1 (k >= 1): the first row
    is 0, 1, k-1, 2, k-2, ..., row i adds i modulo k to it, and an odd k > 1
    also gets every row reversed."""
    if k < 1:
        raise ValueError("a schedule needs at least one arm, not %r" % (k,))
    first, lo, hi, take_lo = [0], 1, k - 1, True
    while lo <= hi:
        if take_lo:
            first.append(lo)
            lo += 1
        else:
            first.append(hi)
            hi -= 1
        take_lo = not take_lo
    rows = [[(x + i) % k for x in first] for i in range(k)]
    if k % 2 and k > 1:
        rows += [row[::-1] for row in rows]
    return rows


def cycle(k):
    """Rounds in a full cycle of the square: k for an even k (and k = 1),
    2k for an odd k > 1."""
    return 2 * k if k % 2 and k > 1 else k


def round_orders(r, k, reps):
    """The arm order of each replicate of round r (0-based): the square's row
    r mod cycle(k), then alternately its reverse and itself."""
    if reps < 1:
        raise ValueError("a round needs at least one replicate, not %r" % (reps,))
    row = williams(k)[r % cycle(k)]
    return [list(row) if i % 2 == 0 else row[::-1] for i in range(reps)]


def plan(seeds, k, reps):
    """Every timed run of an experiment in order, as (round, seed, rep, pos,
    arm) tuples: one round per seed, in the order given."""
    out = []
    for r, seed in enumerate(seeds):
        for rep, order in enumerate(round_orders(r, k, reps)):
            for pos, arm in enumerate(order):
                out.append((r, seed, rep, pos, arm))
    return out
