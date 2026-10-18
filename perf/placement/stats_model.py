"""The run-order model of stats.py: the position effects, the within-round
drift and the run noise of one workload item, fitted jointly.

Every timed run's y = ln t is modelled as

  y = c[r,a] + b[pos] + beta * (slot - centre) + e

with c[r,a] a free effect per (seed, arm) cell (it holds the arm's effect,
its placement and anything common to the round), b[pos] the effect of the
run's position in its replicate's order (centred: the mean over positions is
0), beta the drift per run inside a round, slot = rep * k + pos the run's
index in its round (k arms), and e the run noise, of variance sigma_run^2.

Under the mirrored schedule (schedule.round_orders) the replicates of a cell
sit at positions p and k-1-p, so a contrast inside a cell sees only b[p] -
b[k-1-p] and the drift, while the rest of b (for an odd k, the middle
position against the others) shows only between cells.  The model is fitted
in two strata, and their estimates of b and beta are combined weighted by
their information (the recovery of inter-block information of incomplete
block designs):

- within cells: y and the order terms minus their cell means.  Least squares
  gives b's within-cell contrasts, beta, and sigma_run^2 as the residual
  variance on sum(n - 1) - rank degrees of freedom (n runs per cell);
- between cells: the cell means, with their seed and arm means swept out, over
  the seeds that ran every arm.  Their residual variance is placement noise
  plus a cell mean's run noise.

Subtracting the fitted order terms from each run gives the adjusted cell
means, whose spread over seeds net of run noise is the placement noise.
Without the model a position effect or a drift inside a cell would be counted
as run noise, and a symmetric position effect as placement noise.

With one replicate per cell there is no within stratum: run noise cannot be
told apart from placement noise, and the drift is confounded with position
(slot = pos), so only position effects are fitted, between cells.

Python standard library only.  The tests are in test_stats.py; nothing runs
them automatically:
  python3 -m unittest discover perf/placement
"""

import math
from collections import defaultdict

import stats_core as sc

METRICS = {"user": lambda s: s.user, "user+sys": lambda s: s.user + s.sys,
           "cycles": lambda s: s.cycles, "insns": lambda s: s.insns}

# The variance used for a stratum that fits its data exactly, so that its
# information stays finite.
TINY_VAR = 1e-24


class Cells:
    """The kept samples of one item by (seed, arm), each as (ln metric, pos,
    rep)."""

    def __init__(self, samples, metric="user", keep=None):
        f = METRICS[metric]
        self.runs = defaultdict(list)
        for s in samples:
            v = f(s)
            if (keep is None or keep(s)) and v is not None and v > 0:
                self.runs[(s.seed, s.arm)].append((math.log(v), s.pos, s.rep))

    def seeds(self, arms):
        """Sorted seeds with at least one value for every arm in arms."""
        common = None
        for a in arms:
            ss = {r for (r, b) in self.runs if b == a}
            common = ss if common is None else common & ss
        return sorted(common or ())

    def means(self, arm, seeds):
        """Per seed, the mean ln metric of the arm's cell."""
        return [sc.mean([y for y, _, _ in self.runs[(r, arm)]]) for r in seeds]


def _outer_add(acc, x, w=1.0):
    for i, xi in enumerate(x):
        if xi:
            row = acc[i]
            for j, xj in enumerate(x):
                row[j] += w * xi * xj


def _dot(x, t):
    return sum(a * b for a, b in zip(x, t))


class OrderModel:
    """The order model (see the module doc) fitted to the cells of the arms
    `arms` of an item run with k arms.

    pos_eff, pos_se: the centred position effects and their standard errors
    (log scale), None when they cannot be estimated; beta, beta_se: the
    drift per run, None when not fitted; strata: the strata used;
    run_var: arm -> sigma_run^2, empty without a within stratum."""

    def __init__(self, cells, k, arms):
        self.cells, self.k, self.arms = cells, k, list(arms)
        self.keys = sorted(key for key in cells.runs if key[1] in set(self.arms))
        reps = {rep for key in self.keys for _, _, rep in cells.runs[key]}
        self.nrep = max(reps) + 1 if reps else 1
        self.centre = (self.nrep * k - 1) / 2.0
        self.pos_eff = self.pos_se = self.beta = self.beta_se = None
        self.strata, self.run_var, self.theta = [], {}, None
        if not self._fit(len(reps) >= 2):
            self._fit(False)

    def _x(self, pos, rep, slot):
        x = [1.0 if pos == p else 0.0 for p in range(1, self.k)]
        if slot:
            x.append(float(rep * self.k + pos))
        return x

    def _within(self, slot, p):
        """(A, b, dof, rows) of the within-cell stratum; rows: cell ->
        [(y - cell mean, x - cell mean)]."""
        a, b, rows, nfree = [[0.0] * p for _ in range(p)], [0.0] * p, {}, 0
        for key in self.keys:
            runs = self.cells.runs[key]
            if len(runs) < 2:
                continue
            xs = [self._x(pos, rep, slot) for _, pos, rep in runs]
            ym = sc.mean([y for y, _, _ in runs])
            xm = [sc.mean([x[j] for x in xs]) for j in range(p)]
            cell = []
            for (y, _, _), x in zip(runs, xs):
                xt = [x[j] - xm[j] for j in range(p)]
                _outer_add(a, xt)
                for j in range(p):
                    b[j] += xt[j] * (y - ym)
                cell.append((y - ym, xt))
            rows[key] = cell
            nfree += len(runs) - 1
        return a, b, nfree, rows

    def _between(self, slot, p):
        """(A, b, rows) of the between-cell stratum over the seeds that ran
        every arm: cell means with seed and arm means swept out."""
        seeds = self.cells.seeds(self.arms)
        a, b, rows = [[0.0] * p for _ in range(p)], [0.0] * p, []
        if len(seeds) < 2 or len(self.arms) < 2:
            return a, b, rows
        cm = {}
        for r in seeds:
            for arm in self.arms:
                runs = self.cells.runs[(r, arm)]
                xs = [self._x(pos, rep, slot) for _, pos, rep in runs]
                cm[(r, arm)] = [sc.mean([y for y, _, _ in runs])] + \
                    [sc.mean([x[j] for x in xs]) for j in range(p)]
        width = p + 1
        row_m = {r: [sc.mean([cm[(r, x)][j] for x in self.arms]) for j in range(width)]
                 for r in seeds}
        col_m = {x: [sc.mean([cm[(r, x)][j] for r in seeds]) for j in range(width)]
                 for x in self.arms}
        grand = [sc.mean([row_m[r][j] for r in seeds]) for j in range(width)]
        for r in seeds:
            for arm in self.arms:
                v = [cm[(r, arm)][j] - row_m[r][j] - col_m[arm][j] + grand[j]
                     for j in range(width)]
                _outer_add(a, v[1:])
                for j in range(p):
                    b[j] += v[1 + j] * v[0]
                rows.append((v[0], v[1:]))
        return a, b, rows

    def _fit(self, slot):
        """Fit with or without the drift term; False when the combined
        information is singular with it (so the caller refits without)."""
        p = self.k - 1 + (1 if slot else 0)
        self._ss, self._frac = {}, 0.0
        aw, bw, nfree, wrows = self._within(slot, p)
        ab, bb, brows = self._between(slot, p)
        info, rhs, strata = [[0.0] * p for _ in range(p)], [0.0] * p, []
        tw, rank_w = sc.solve(aw, bw) if p else ([], 0)
        dof_w = nfree - rank_w
        if wrows and dof_w > 0:
            rss = 0.0
            for key, cell in wrows.items():
                self._ss[key] = sum((e - _dot(x, tw)) ** 2 for e, x in cell)
                rss += self._ss[key]
            var_w = max(rss / dof_w, TINY_VAR)
            self._frac = dof_w / float(nfree)
            self._add(info, rhs, aw, bw, var_w)
            strata.append("within")
        if brows:
            tb, rank_b = sc.solve(ab, bb) if p else ([], 0)
            dof_b = len(brows) - len(self.cells.seeds(self.arms)) - len(self.arms) + 1 - rank_b
            if dof_b > 0:
                rss = sum((e - _dot(x, tb)) ** 2 for e, x in brows)
                self._add(info, rhs, ab, bb, max(rss / dof_b, TINY_VAR))
                strata.append("between")
        self.strata = strata
        self.theta, _ = sc.solve(info, rhs) if p else ([], 0)
        cov = sc.inverse(info) if p else []
        if cov is None and slot:
            return False
        self._slot = slot
        self._estimates(cov, slot)
        self.run_var = {}
        for arm in self.arms:
            ss = sum(v for key, v in self._ss.items() if key[1] == arm)
            free = sum(len(self.cells.runs[key]) - 1 for key in self._ss if key[1] == arm)
            if free and self._frac:
                self.run_var[arm] = ss / (free * self._frac)
        return True

    @staticmethod
    def _add(info, rhs, a, b, var):
        for i in range(len(b)):
            rhs[i] += b[i] / var
            for j in range(len(b)):
                info[i][j] += a[i][j] / var

    def _estimates(self, cov, slot):
        k, th = self.k, self.theta
        b = [0.0] + list(th[:k - 1])
        mb = sc.mean(b)
        eff = [x - mb for x in b]
        self._off_pos = eff
        self._beta = th[k - 1] if slot else 0.0
        if cov is None or not self.strata:
            return
        se = []
        for p in range(k):
            lvec = [(1.0 if j + 1 == p else 0.0) - 1.0 / k for j in range(k - 1)]
            v = sum(lvec[i] * cov[i][j] * lvec[j] for i in range(k - 1) for j in range(k - 1))
            se.append(math.sqrt(max(v, 0.0)))
        self.pos_eff, self.pos_se = eff, se
        if slot:
            self.beta, self.beta_se = self._beta, math.sqrt(max(cov[k - 1][k - 1], 0.0))

    def offset(self, pos, rep):
        """The fitted order term of a run at (pos, rep), on the log scale."""
        off = self._off_pos[pos] if 0 <= pos < self.k else 0.0
        if self._slot:
            off += self._beta * (rep * self.k + pos - self.centre)
        return off

    def table(self, arm, seeds):
        """Per seed: (adjusted cell mean, residual sum of squares inside the
        cell, its share of the residual degrees of freedom, 1/runs)."""
        out = []
        for r in seeds:
            runs = self.cells.runs[(r, arm)]
            m = sc.mean([y - self.offset(pos, rep) for y, pos, rep in runs])
            key = (r, arm)
            if key in self._ss:
                out.append((m, self._ss[key], (len(runs) - 1) * self._frac, 1.0 / len(runs)))
            else:
                out.append((m, 0.0, 0.0, 1.0 / len(runs)))
        return out
