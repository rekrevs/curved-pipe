"""Executable diagnostic probes for iterative (fixed-point) solvers.

ADSD-style diagnosis (Chen & Yin, arXiv:2610.03872): turn "the solver does not
converge" into "the solver does not converge *because* X", and point at the
retained skill that addresses X. The probes are solver-agnostic: they read an
iteration trace, i.e. one row per outer iteration with any numeric columns
(scalar diagnostics such as phi_M, w_M, max|update|, residual norms, or full
state vectors).

Probes
------
estimate_spectrum      dominant eigenvalue (modulus, angle, period) of the
                       fixed-point map, from successive differences
detect_period          period of a scalar oscillation (2, 3, ...) or None
relaxation_inflation   how much a convergence test on a relaxed increment
                       loosens the tolerance on the raw update
check_false_convergence  "converged" while the equation residual is not small,
                       or a relaxed-increment convergence test
check_nonfinite        NaN/Inf in the trace, or exact zeros that suggest a NaN
                       masked by MAX-style reductions
check_collapse         sudden collapse of a magnitude towards the trivial
                       solution
diagnose               runs everything and maps findings to skills in
                       adsd/skills/

Background for each probe: docs/adsd/retrospective.md (episodes E2, E4, E5).
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np
from numpy.typing import ArrayLike

SKILLS_DIR = Path(__file__).resolve().parent / "skills"


@dataclass
class Finding:
    name: str
    severity: str  # "info" | "warning" | "error"
    message: str
    skills: list[str] = field(default_factory=list)
    data: dict = field(default_factory=dict)


@dataclass
class Spectrum:
    """Dominant mode of the linearised fixed-point map x -> T(x).

    Near a fixed point the differences d_n = x_{n+1} - x_n obey d_{n+1} = J d_n.
    The dominant eigenvalue lambda = rho * exp(i theta) of J is estimated by a
    least-squares linear recurrence (vector Prony) over the late part of the
    trace. Works for any set of observed linear functionals of the state,
    including scalar diagnostics, as long as they see the dominant mode.
    """

    rho: float                  # |lambda|
    theta: float                # arg(lambda) in [0, pi]
    eigenvalue: complex
    period: int | None          # 2 for lambda ~ -1, 3 for theta ~ 2pi/3, ...
    regime: str                 # converged | contractive | stagnating | limit-cycle | divergent
    order: int                  # recurrence order used
    fit_residual: float         # relative LS residual of the recurrence
    empirical_rate: float       # geometric mean of |d_{n+1}| / |d_n| over the window
    rho_after_averaging: float  # |(1 + lambda)/2|: dominant mode after 2-cycle averaging
    window: int
    nonlinear: bool = False     # linear fit inadequate; regime from amplitude analysis
    amplitude_decay: float | None = None  # envelope ratio, second half / first half


def _finite_rows(x: ArrayLike) -> np.ndarray:
    x = np.asarray(x, dtype=float)
    if x.ndim == 1:
        x = x[:, None]
    keep = np.all(np.isfinite(x), axis=1)
    return x[keep]


def _recurrence_fit(d: np.ndarray, k: int) -> tuple[np.ndarray, float]:
    """Fit d_t = sum_{j=1..k} c_j d_{t-j} (shared c for all components)."""
    n, m = d.shape
    rows = []
    rhs = []
    for t in range(k, n):
        rows.append(np.stack([d[t - j] for j in range(1, k + 1)], axis=1))  # (m, k)
        rhs.append(d[t])
    a = np.concatenate(rows, axis=0)
    b = np.concatenate(rhs, axis=0)
    with np.errstate(all="ignore"):
        c, *_ = np.linalg.lstsq(a, b, rcond=None)
        res = np.linalg.norm(a @ c - b) / max(float(np.linalg.norm(b)), 1e-300)
    return c, float(res)


def estimate_spectrum(
    states: ArrayLike,
    max_order: int = 4,
    window: int = 60,
    fit_tol: float = 0.05,
    nonlinear_tol: float = 0.2,
    amp_window: int = 400,
) -> Spectrum:
    """Estimate the dominant eigenvalue of the fixed-point map from iterates.

    `states` is (n_iter, n_obs): iterates or any observed functionals of them.
    """
    x = _finite_rows(states)
    d = np.diff(x, axis=0)
    norms = np.linalg.norm(d, axis=1)
    if len(d) < 4 or norms.max() == 0.0:
        return Spectrum(0.0, 0.0, 0j, None, "converged", 0, 0.0, 0.0, 0.5, len(d))

    # Drop the tail once the increments are at round-off level.
    floor = 1e-11 * norms.max()
    last = int(np.nonzero(norms > floor)[0][-1]) + 1
    d = d[:last]
    d = d[-window:]
    if len(d) < 4:
        return Spectrum(0.0, 0.0, 0j, None, "converged", 0, 0.0, 0.0, 0.5, len(d))

    scale = np.sqrt(np.mean(d * d, axis=0))
    scale[scale == 0.0] = 1.0
    ds = d / scale

    best = None
    for k in range(1, max_order + 1):
        if len(ds) - k < max(3, k + 1):
            break
        c, res = _recurrence_fit(ds, k)
        if best is None or res < best[2] - 1e-12:
            best = (k, c, res)
        if res < fit_tol:
            best = (k, c, res)
            break
    assert best is not None
    k, c, res = best
    roots = np.roots(np.concatenate([[1.0], -c]))
    lam = complex(roots[np.argmax(np.abs(roots))])
    if lam.imag < 0:
        lam = lam.conjugate()
    rho = abs(lam)
    theta = abs(math.atan2(lam.imag, lam.real))

    # only pairs of resolved increments: traces printed with few digits contain
    # repeated rows (zero increments), which would give 0 or 1e300 ratios
    dn = np.linalg.norm(ds, axis=1)
    ok = dn > 1e-9 * dn.max()
    pair = ok[1:] & ok[:-1]
    ratios = dn[1:][pair] / dn[:-1][pair]
    empirical = float(np.exp(np.mean(np.log(ratios)))) if len(ratios) else 0.0

    period = None
    if theta > 0.1:
        p = 2 * math.pi / theta
        if abs(p - round(p)) < 0.15 and 2 <= round(p) <= 64:
            period = int(round(p))

    if rho > 1.02:
        regime = "divergent"
    elif rho >= 0.98:
        regime = "limit-cycle" if theta > 0.1 else "stagnating"
    else:
        regime = "contractive"

    nonlinear = False
    decay = None
    if res > nonlinear_tol and len(x) >= 40:
        osc = _sustained_oscillation(x[-amp_window:])
        if osc is not None:
            nonlinear = True
            decay, p_nl = osc
            regime = "divergent" if decay > 1.5 else "limit-cycle"
            rho = decay ** (2.0 / min(len(x), amp_window))
            if p_nl is not None:
                period = p_nl
                theta = 2 * math.pi / p_nl
                lam = complex(rho * math.cos(theta), rho * math.sin(theta))

    return Spectrum(
        rho=rho,
        theta=theta,
        eigenvalue=lam,
        period=period,
        regime=regime,
        order=k,
        fit_residual=res,
        empirical_rate=empirical,
        rho_after_averaging=abs((1 + lam) / 2),
        window=len(d),
        nonlinear=nonlinear,
        amplitude_decay=decay,
    )


def _sustained_oscillation(x: np.ndarray, min_decay: float = 0.6,
                           min_rel: float = 1e-4) -> tuple[float, int | None] | None:
    """Amplitude test for oscillations the linear recurrence cannot fit.

    Returns (envelope ratio second/first half, approximate period) if the
    oscillation does not decay, else None.
    """
    rel = np.std(x, axis=0) / np.maximum(np.abs(np.mean(x, axis=0)), 1e-300)
    j = int(np.argmax(rel))
    if rel[j] < min_rel:
        return None
    v = x[:, j] - np.mean(x[:, j])
    h = len(v) // 2
    a1, a2 = np.std(v[:h]), np.std(v[h:])
    if a1 == 0.0:
        return None
    decay = float(a2 / a1)
    if decay < min_decay:
        return None
    # approximate period: first autocorrelation peak after the first negative lobe
    n = len(v)
    ac = np.array([np.dot(v[:n - k], v[k:]) for k in range(n // 3)])
    ac = ac / ac[0]
    period = None
    neg = np.nonzero(ac < 0)[0]
    if len(neg):
        k0 = int(neg[0])
        for k in range(k0 + 1, len(ac) - 1):
            if ac[k] > 0.2 and ac[k] >= ac[k - 1] and ac[k] >= ac[k + 1]:
                period = k
                break
    return decay, period


def detect_period(x: ArrayLike, max_period: int = 8, window: int = 60,
                  threshold: float = 0.9) -> tuple[int | None, float]:
    """Period of a scalar oscillation via normalised lag correlation of increments.

    Returns (period, strength); period is None for monotone or aperiodic series.
    """
    v = np.asarray(x, dtype=float)
    v = v[np.isfinite(v)][-(window + 1):]
    d = np.diff(v)
    if len(d) < 2 * max_period or np.max(np.abs(d)) == 0.0:
        return None, 0.0
    for lag in range(1, max_period + 1):
        a, b = d[:-lag], d[lag:]
        corr = float(np.dot(a, b) / max(float(np.linalg.norm(a) * np.linalg.norm(b)), 1e-300))
        if corr > threshold:
            return (None, corr) if lag == 1 else (lag, corr)
    return None, 0.0


def relaxation_inflation(xi: float) -> float:
    """Tolerance inflation of a convergence test on a relaxed increment.

    With relaxed = xi*old + (1-xi)*raw, |old - relaxed| = (1-xi)|old - raw|,
    so testing |old - relaxed| < eps accepts raw updates up to eps/(1-xi).
    """
    return math.inf if xi >= 1.0 else 1.0 / (1.0 - xi)


def check_false_convergence(
    steps: ArrayLike | None,
    residuals: ArrayLike | None,
    step_tol: float,
    res_tol: float | None,
    xi: float | None = None,
) -> Finding | None:
    """Flag convergence that is declared on increments but not on the equation."""
    if xi is not None:
        infl = relaxation_inflation(xi)
        if infl > 2.0:
            return Finding(
                "false-convergence-risk", "warning",
                f"convergence tested on a relaxed increment (xi={xi:g}) accepts raw "
                f"updates up to {infl:.0f}x the tolerance; heavy damping then looks like "
                f"convergence. Test |old-relaxed| < (1-xi)*eps instead.",
                ["unrelaxed-convergence-test"], {"inflation": infl})
    if steps is not None and residuals is not None and res_tol is not None:
        s = np.asarray(steps, dtype=float)
        r = np.asarray(residuals, dtype=float)
        if s[-1] < step_tol and r[-1] > res_tol:
            return Finding(
                "false-convergence", "error",
                f"increments are below tolerance ({s[-1]:.3g} < {step_tol:g}) but the "
                f"equation residual is {r[-1]:.3g} > {res_tol:g}: the iteration has stalled "
                f"(over-damping or a relaxed convergence test), not converged.",
                ["unrelaxed-convergence-test"],
                {"last_step": float(s[-1]), "last_residual": float(r[-1])})
    return None


def check_nonfinite(states: ArrayLike) -> Finding | None:
    """NaN/Inf in the trace, or a healthy magnitude that becomes exactly 0."""
    x = np.asarray(states, dtype=float)
    if x.ndim == 1:
        x = x[:, None]
    bad = ~np.isfinite(x)
    if bad.any():
        it = int(np.nonzero(bad.any(axis=1))[0][0])
        return Finding("non-finite", "error",
                       f"non-finite values from row {it}; check every reduction "
                       f"(MAX/MAXVAL ignore NaN in gfortran) and abort on NaN.",
                       ["nan-safe-reductions"], {"first_row": it})
    if len(x) >= 6:
        prev = np.abs(x[-6:-1])
        hit = (x[-1] == 0.0) & (prev.min(axis=0) > 1e-8)
        if hit.any():
            return Finding("masked-nan-suspect", "warning",
                           "a quantity that was O(1) became exactly 0.0 in the last row; "
                           "typical of a diverged (NaN) field reported through MAX-style "
                           "reductions or `x > 0` tests that are false for NaN.",
                           ["nan-safe-reductions"], {"columns": np.nonzero(hit)[0].tolist()})
    return None


def check_collapse(x: ArrayLike, frac: float = 0.5, window: int = 10) -> Finding | None:
    """Flag a magnitude that ends below `frac` of its largest rolling median.

    Catches both a collapse in the last row and one that happened earlier in
    the trace (the iteration then sits at the trivial solution).
    """
    v = np.abs(np.asarray(x, dtype=float))
    v = v[np.isfinite(v)]
    if len(v) < 3:
        return None
    w = min(window, len(v) - 1)
    # reference = largest median over a window where the value was on a plateau
    # (relative spread < 25%), so a transient decaying from a large initial
    # guess is not mistaken for a collapse
    meds = []
    for i in range(0, len(v) - w):
        seg = v[i:i + w]
        med = float(np.median(seg))
        meds.append(med if med > 0 and (seg.max() - seg.min()) < 0.25 * med else 0.0)
    if not meds:
        return None
    k = int(np.argmax(meds))
    ref = float(meds[k])
    if ref > 0 and v[-1] < frac * ref:
        drop = k + w + int(np.argmax(v[k + w:] < frac * ref)) if k + w < len(v) else len(v) - 1
        tail = max(1, (len(v) - drop + 1) // 2)
        if np.any(v[-tail:] >= frac * ref):
            return None  # it keeps coming back up: oscillation troughs, not a collapse
        return Finding("collapse-to-trivial", "error",
                       f"final value {v[-1]:.3g} < {frac:g} x peak rolling median {ref:.3g} "
                       f"(first below at row {drop}): the iteration left the basin of the "
                       f"nontrivial solution.",
                       ["anderson-acceleration", "continuation-handoff"],
                       {"final": float(v[-1]), "reference": ref, "first_row_below": drop})
    return None


def diagnose(
    trace: dict[str, np.ndarray],
    state_cols: Sequence[str] | None = None,
    step_col: str | None = None,
    residual_col: str | None = None,
    step_tol: float = 1e-6,
    res_tol: float | None = None,
    xi: float | None = None,
    skip: int = 0,
) -> list[Finding]:
    """Run all probes on a trace and map the findings to skills."""
    cols = list(state_cols) if state_cols else [c for c in trace if c.lower() not in ("iter", "it", "n")]
    x = np.column_stack([np.asarray(trace[c], dtype=float)[skip:] for c in cols])
    findings: list[Finding] = []

    f = check_nonfinite(x)
    if f:
        findings.append(f)
    for j, c in enumerate(cols):
        f = check_collapse(x[:, j])
        if f:
            f.data["column"] = c
            findings.append(f)
            break

    steps = trace[step_col][skip:] if step_col else None
    res = trace[residual_col][skip:] if residual_col else None
    f = check_false_convergence(steps, res, step_tol, res_tol, xi)
    if f:
        findings.append(f)

    if len(x) < 12:
        findings.append(Finding(
            "short-trace", "warning",
            f"only {len(x)} iterations: eigenvalue estimates from so few rows are unreliable; "
            f"trace at least ~20 iterations at a fixed parameter value.", [], {"rows": len(x)}))

    s = estimate_spectrum(x)
    finite_x = x[np.all(np.isfinite(x), axis=1)]
    if (len(finite_x) and np.all(finite_x >= 0) and s.theta < 0.1 and s.rho >= 0.9):
        findings.append(Finding(
            "sign-ambiguous", "warning",
            "all observables are nonnegative magnitudes (e.g. max|field|): an alternating "
            "mode (lambda < 0) in a field that crosses zero shows up here as lambda > 0. "
            "Add signed point values (e.g. PHI at a fixed interior point) before trusting "
            "the sign of lambda.", [], {"rho": s.rho}))
    sd = asdict(s)
    sd["eigenvalue"] = [s.eigenvalue.real, s.eigenvalue.imag]
    lam = f"lambda ~ {s.eigenvalue.real:+.3f}{s.eigenvalue.imag:+.3f}i (|lambda|={s.rho:.3f})"
    oscillatory = s.period is not None or s.theta > math.pi / 2
    if s.regime == "converged":
        findings.append(Finding("converged", "info", "increments vanish", [], sd))
    elif (oscillatory or s.regime == "limit-cycle") and (s.rho >= 0.9 or s.regime != "contractive"):
        skills = []
        if s.rho_after_averaging < s.rho:
            skills.append("two-cycle-averaging")
        if s.rho >= 1.0 or s.rho_after_averaging >= 0.95:
            skills.append("anderson-acceleration")
        if s.rho > 1.5:
            skills.append("nonlinear-gauss-seidel")
        per = f"period-{s.period}" if s.period else "aperiodic"
        kind = (f"nonlinear (linear fit residual {s.fit_residual:.2f}), amplitude ratio "
                f"{s.amplitude_decay:.2f} over the window" if s.nonlinear else lam)
        msg = (f"{per} oscillation, {s.regime}: {kind}. 2-cycle averaging maps the dominant "
               f"mode to |(1+lambda)/2| = {s.rho_after_averaging:.3f}.")
        lam_r = s.eigenvalue.real
        if not s.nonlinear and abs(s.theta - math.pi) < 0.1 and lam_r < 0:
            # x <- xi*x + (1-xi)*T(x) maps lambda -> xi + (1-xi)*lambda: zero at xi*
            xi_opt = lam_r / (lam_r - 1.0)
            sd["optimal_xi"] = xi_opt
            msg += (f" For this real mode the optimal relaxation weight on the old iterate is "
                    f"xi = lambda/(lambda-1) = {xi_opt:.2f} (other modes may limit it).")
        findings.append(Finding(
            "oscillation", "error" if s.rho >= 0.98 else "warning", msg, skills, sd))
    elif s.rho >= 0.95:
        skills = ["anderson-acceleration"]
        if s.regime == "divergent":
            skills.append("continuation-handoff")
        if s.rho > 1.5:
            skills.append("nonlinear-gauss-seidel")
        findings.append(Finding(
            "slow-monotone" if s.regime != "divergent" else "divergent", "warning",
            f"dominant mode is real positive, {s.regime}: {lam}. Under-relaxation and "
            f"averaging make this slower; use acceleration (or continuation if divergent).",
            skills, sd))
    else:
        findings.append(Finding("contractive", "info",
                                f"iteration contracts: {lam}, empirical rate {s.empirical_rate:.3f}",
                                [], sd))
    return findings


def load_trace(path: str | Path) -> dict[str, np.ndarray]:
    """Read a CSV or whitespace-separated trace with a header row.

    Lines starting with '#' and blank lines are skipped. Fortran-style NaN /
    Infinity tokens are accepted.
    """
    header: list[str] | None = None
    rows: list[list[float]] = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        toks = [t for t in (s.split(",") if "," in s else s.split()) if t != ""]
        if header is None:
            header = toks
            continue
        vals = []
        for t in toks:
            try:
                vals.append(float(t))
            except ValueError:
                vals.append(math.nan)
        if len(vals) == len(header):
            rows.append(vals)
    if header is None:
        raise ValueError(f"{path}: no header row")
    arr = np.array(rows, dtype=float).reshape(-1, len(header))
    return {h: arr[:, i] for i, h in enumerate(header)}


def format_report(findings: list[Finding]) -> str:
    out = []
    for f in findings:
        out.append(f"[{f.severity.upper()}] {f.name}: {f.message}")
        for s in f.skills:
            out.append(f"    -> skill: {s}  ({SKILLS_DIR / (s + '.md')})")
    return "\n".join(out)


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="python -m adsd.probes",
        description="Diagnose an iteration trace (one row per outer iteration).")
    p.add_argument("trace")
    p.add_argument("--state", help="comma-separated state/diagnostic columns (default: all but iter)")
    p.add_argument("--step", help="column with max|update| per iteration")
    p.add_argument("--residual", help="column with an equation residual per iteration")
    p.add_argument("--step-tol", type=float, default=1e-6)
    p.add_argument("--res-tol", type=float)
    p.add_argument("--xi", type=float, help="relaxation factor used in the convergence test")
    p.add_argument("--skip", type=int, default=0, help="ignore the first N rows")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    t = load_trace(a.trace)
    findings = diagnose(t, a.state.split(",") if a.state else None, a.step, a.residual,
                        a.step_tol, a.res_tol, a.xi, a.skip)
    if a.json:
        print(json.dumps([asdict(f) for f in findings], indent=2, default=str))
    else:
        print(format_report(findings))
    return 1 if any(f.severity == "error" for f in findings) else 0


if __name__ == "__main__":
    raise SystemExit(main())
