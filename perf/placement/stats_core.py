"""Numerical helpers for stats.py: moments, quantiles, Student's t, the seed
bootstrap and simple regression.

The bootstrap resamples placement seeds (the unit an experiment draws at
random) with replacement.  Resample index lists come from random.Random with a
fixed seed and are shared by every statistic of one analysis, so results are
reproducible and a joint statistic (a geometric mean over workloads, a
difference between two arms) is bootstrapped over the same seed draws as its
parts.

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import math
import random


def mean(xs):
    return sum(xs) / len(xs)


def var(xs):
    """Sample variance (n - 1 denominator); 0.0 for fewer than two values."""
    n = len(xs)
    if n < 2:
        return 0.0
    m = mean(xs)
    return sum((x - m) ** 2 for x in xs) / (n - 1)


def sd(xs):
    return math.sqrt(var(xs))


def quantile(xs, q):
    """Linearly interpolated quantile (the usual 'type 7') of xs, which may
    hold infinities: between a finite value and an infinite one it is
    infinite."""
    s = sorted(xs)
    if not s:
        raise ValueError("quantile of no values")
    h = (len(s) - 1) * q
    lo = math.floor(h)
    hi = min(lo + 1, len(s) - 1)
    if h == lo or s[lo] == s[hi]:
        return s[lo]
    return s[lo] + (h - lo) * (s[hi] - s[lo])


def solve(a, b, tol=1e-10):
    """(x, rank) for the symmetric positive semi-definite system a x = b (a
    as a list of rows), such as least-squares normal equations: Gauss-Jordan
    elimination with partial pivoting, where a column whose pivot is below
    tol times the largest diagonal entry is taken as dependent and its
    unknown set to 0.  For consistent normal equations that still gives a
    least-squares solution."""
    n = len(a)
    m = [list(map(float, row)) + [float(b[i])] for i, row in enumerate(a)]
    scale = max([abs(a[i][i]) for i in range(n)] + [0.0]) or 1.0
    where, r = [-1] * n, 0
    for c in range(n):
        if r == n:
            break
        p = max(range(r, n), key=lambda i: abs(m[i][c]))
        if abs(m[p][c]) <= tol * scale:
            continue
        m[r], m[p] = m[p], m[r]
        pv = m[r][c]
        for i in range(n):
            if i != r and m[i][c] != 0.0:
                f = m[i][c] / pv
                for j in range(c, n + 1):
                    m[i][j] -= f * m[r][j]
        where[c] = r
        r += 1
    x = [m[where[c]][n] / m[where[c]][c] if where[c] >= 0 else 0.0 for c in range(n)]
    return x, r


def inverse(a, tol=1e-10):
    """The inverse of the symmetric positive definite matrix a, or None when
    it is singular (see solve)."""
    n = len(a)
    cols = []
    for j in range(n):
        x, rank = solve(a, [1.0 if i == j else 0.0 for i in range(n)], tol)
        if rank < n:
            return None
        cols.append(x)
    return [[cols[j][i] for j in range(n)] for i in range(n)]


def _betacf(a, b, x):
    # Continued fraction of the incomplete beta function (modified Lentz).
    tiny, eps = 1e-300, 3e-16
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 400):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def betainc(a, b, x):
    """The regularized incomplete beta function I_x(a, b)."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    ln = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
          + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return math.exp(ln) * _betacf(a, b, x) / a
    return 1.0 - math.exp(ln) * _betacf(b, a, 1.0 - x) / b


def t_cdf(t, df):
    """P(T <= t) for Student's t with df degrees of freedom.  The tail
    P(|T| > |t|) is I_x(df/2, 1/2) at x = df / (df + t^2), and its
    complement I_y(1/2, df/2) at y = t^2 / (df + t^2): whichever of x, y is
    smaller is evaluated, so neither is formed as 1 minus the other."""
    t2 = t * t
    x, y = df / (df + t2), t2 / (df + t2)
    if x < y:
        tail = betainc(df / 2.0, 0.5, x)
    else:
        tail = 1.0 - betainc(0.5, df / 2.0, y)
    return 1.0 - 0.5 * tail if t > 0 else 0.5 * tail


def t_ppf(p, df):
    """The p quantile of Student's t with df degrees of freedom."""
    if not 0.0 < p < 1.0:
        raise ValueError("t quantile needs 0 < p < 1, not %r" % (p,))
    lo, hi = -1e6, 1e6
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if t_cdf(mid, df) < p:
            lo = mid
        else:
            hi = mid
        if hi - lo < 1e-12 * max(1.0, abs(mid)):
            break
    return 0.5 * (lo + hi)


def t_interval(xs, level=0.95):
    """(lo, hi) Student-t confidence interval for the mean of xs; (nan, nan)
    for fewer than two values."""
    n = len(xs)
    if n < 2:
        return (float("nan"), float("nan"))
    half = t_ppf(0.5 + level / 2.0, n - 1) * sd(xs) / math.sqrt(n)
    m = mean(xs)
    return (m - half, m + half)


class Resampler:
    """B bootstrap draws of n seed indices, from random.Random(seed)."""

    def __init__(self, b, seed):
        self.b, self.seed, self._cache = b, seed, {}

    def draws(self, n):
        if n not in self._cache:
            rng = random.Random("%d/%d/%d" % (self.seed, self.b, n))
            self._cache[n] = [[rng.randrange(n) for _ in range(n)] for _ in range(self.b)]
        return self._cache[n]

    def ci(self, n, stat, level=0.95):
        """Percentile interval of stat(indices) over the draws (draws where
        stat returns None are skipped); (nan, nan) when none remain."""
        vals = [v for v in (stat(ix) for ix in self.draws(n)) if v is not None]
        if not vals:
            return (float("nan"), float("nan"))
        a = (1.0 - level) / 2.0
        return (quantile(vals, a), quantile(vals, 1.0 - a))


def pearson(xs, ys):
    """Correlation coefficient, or None when either side is constant."""
    if len(xs) < 3:
        return None
    mx, my = mean(xs), mean(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def ols(xs, ys):
    """(slope, its standard error) of the least-squares line through (xs,
    ys); (None, None) when xs is constant or there are fewer than 3 points."""
    n = len(xs)
    if n < 3:
        return (None, None)
    mx, my = mean(xs), mean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return (None, None)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    resid = sum((y - my - slope * (x - mx)) ** 2 for x, y in zip(xs, ys))
    return slope, math.sqrt(resid / (n - 2) / sxx)


def pct(log_ratio):
    """A difference of natural logs as a percentage change."""
    return 100.0 * math.expm1(log_ratio)
