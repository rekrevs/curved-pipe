"""Tests for adsd.probes on fixed-point maps with known spectra."""

import math

import numpy as np
import pytest

from adsd.probes import (
    check_collapse,
    check_false_convergence,
    check_nonfinite,
    detect_period,
    diagnose,
    estimate_spectrum,
    load_trace,
    relaxation_inflation,
)


def _orthogonal(n, seed):
    rng = np.random.default_rng(seed)
    q, _ = np.linalg.qr(rng.standard_normal((n, n)))
    return q


def _linear_iterates(blocks, n_iter=120, seed=0):
    """Iterate x_{n+1} = J x_n + b where J has prescribed eigen-blocks.

    `blocks` is a list of real eigenvalues (float) or complex pairs
    (complex, contributing a 2x2 rotation-scaling block).
    """
    diag = []
    for lam in blocks:
        if isinstance(lam, complex):
            r, t = abs(lam), math.atan2(lam.imag, lam.real)
            diag.append(r * np.array([[math.cos(t), -math.sin(t)],
                                      [math.sin(t), math.cos(t)]]))
        else:
            diag.append(np.array([[lam]]))
    n = sum(b.shape[0] for b in diag)
    a = np.zeros((n, n))
    k = 0
    for b in diag:
        m = b.shape[0]
        a[k:k + m, k:k + m] = b
        k += m
    q = _orthogonal(n, seed)
    j = q @ a @ q.T
    rng = np.random.default_rng(seed + 1)
    b = rng.standard_normal(n)
    x = rng.standard_normal(n) * 10.0
    xs = [x]
    for _ in range(n_iter):
        x = j @ x + b
        xs.append(x)
    return np.array(xs)


def test_period2_negative_eigenvalue():
    xs = _linear_iterates([-0.98, 0.3, 0.1, -0.2])
    s = estimate_spectrum(xs)
    assert s.rho == pytest.approx(0.98, abs=0.01)
    assert abs(s.theta) == pytest.approx(math.pi, abs=0.05)
    assert s.period == 2
    # 2-cycle averaging maps lambda -> (1+lambda)/2
    assert s.rho_after_averaging == pytest.approx(0.01, abs=0.02)


def test_period3_complex_pair():
    lam = 0.95 * complex(math.cos(2 * math.pi / 3), math.sin(2 * math.pi / 3))
    xs = _linear_iterates([lam, 0.2, -0.1])
    s = estimate_spectrum(xs)
    assert s.rho == pytest.approx(0.95, abs=0.01)
    assert abs(s.theta) == pytest.approx(2 * math.pi / 3, abs=0.05)
    assert s.period == 3
    assert s.rho_after_averaging == pytest.approx(abs((1 + lam) / 2), abs=0.02)


def test_monotone_slow_contraction():
    xs = _linear_iterates([0.97, 0.4, -0.3])
    s = estimate_spectrum(xs)
    assert s.rho == pytest.approx(0.97, abs=0.01)
    assert abs(s.theta) < 0.05
    assert s.period is None
    # averaging does not help a positive eigenvalue
    assert s.rho_after_averaging > s.rho


def test_divergent_oscillation():
    xs = _linear_iterates([-1.05, 0.5], n_iter=60)
    s = estimate_spectrum(xs)
    assert s.rho == pytest.approx(1.05, abs=0.01)
    assert s.regime == "divergent"


def test_scalar_observables_of_hidden_state():
    """Only two scalar functionals of a 6-dim state are observed."""
    xs = _linear_iterates([-0.97, 0.5, 0.3, -0.4, 0.2, 0.1], n_iter=150)
    obs = np.column_stack([xs[:, 0] + 2 * xs[:, 3], xs[:, 5]])
    s = estimate_spectrum(obs)
    assert s.rho == pytest.approx(0.97, abs=0.02)
    assert s.period == 2


def test_nonlinear_limit_cycle_period2():
    """Logistic map r=3.2 has an attracting period-2 orbit."""
    x = 0.3
    xs = []
    for _ in range(300):
        x = 3.2 * x * (1 - x)
        xs.append(x)
    s = estimate_spectrum(np.array(xs)[:, None])
    assert s.period == 2
    assert s.rho == pytest.approx(1.0, abs=0.02)
    assert s.regime == "limit-cycle"


def test_detect_period_scalar():
    rng = np.random.default_rng(3)
    n = np.arange(200)
    x3 = 5 + np.cos(2 * math.pi * n / 3) + 0.01 * rng.standard_normal(200)
    assert detect_period(x3)[0] == 3
    x2 = 5 + (-1.0) ** n + 0.01 * rng.standard_normal(200)
    assert detect_period(x2)[0] == 2
    xm = 5 + 0.9 ** n
    assert detect_period(xm)[0] is None


def test_relaxation_inflation():
    # relaxed = xi*old + (1-xi)*raw  =>  |old - relaxed| = (1-xi)|old - raw|
    assert relaxation_inflation(0.9) == pytest.approx(10.0)
    assert relaxation_inflation(0.0) == pytest.approx(1.0)


def test_false_convergence_flagged():
    steps = np.geomspace(1.0, 1e-5, 50)          # increments vanish ...
    residuals = np.full(50, 3.0)                 # ... but the equation is not satisfied
    f = check_false_convergence(steps, residuals, step_tol=1e-4, res_tol=1e-2)
    assert f is not None
    assert f.name == "false-convergence"
    ok = check_false_convergence(steps, np.geomspace(1.0, 1e-5, 50), 1e-4, 1e-2)
    assert ok is None


def test_false_convergence_from_relaxation_factor():
    f = check_false_convergence(None, None, step_tol=1e-3, res_tol=None, xi=0.9)
    assert f is not None and "10" in f.message


def test_nonfinite_and_masked_nan():
    x = np.ones((20, 2))
    x[15, 1] = np.nan
    g = check_nonfinite(x)
    assert g is not None and g.name == "non-finite"
    # A healthy magnitude that suddenly becomes exactly 0: the gfortran
    # MAX(a, NaN) = a masking symptom.
    y = np.column_stack([np.linspace(10, 20, 20), np.linspace(300, 400, 20)])
    y[-1, :] = 0.0
    f = check_nonfinite(y)
    assert f is not None and f.name == "masked-nan-suspect"
    assert check_nonfinite(np.ones((20, 2))) is None


def test_collapse_to_trivial():
    w = np.concatenate([np.linspace(400, 430, 30), [5e-3]])
    g = check_collapse(w)
    assert g is not None and g.name == "collapse-to-trivial"
    assert check_collapse(np.linspace(400, 430, 30)) is None


def test_diagnose_recommends_skills():
    xs = _linear_iterates([-0.99, 0.2])
    findings = diagnose({"x0": xs[:, 0], "x1": xs[:, 1]}, state_cols=["x0", "x1"])
    names = {f.name for f in findings}
    assert "oscillation" in names
    skills = {s for f in findings for s in f.skills}
    assert "two-cycle-averaging" in skills

    xs = _linear_iterates([0.995, 0.2])
    findings = diagnose({"x0": xs[:, 0], "x1": xs[:, 1]}, state_cols=["x0", "x1"])
    skills = {s for f in findings for s in f.skills}
    assert "anderson-acceleration" in skills
    assert "two-cycle-averaging" not in skills


def test_load_trace(tmp_path):
    p = tmp_path / "t.csv"
    p.write_text("# comment\niter,phi_M,w_M\n1,1.0,2.0\n2,1.5,2.5\n")
    t = load_trace(p)
    assert list(t) == ["iter", "phi_M", "w_M"]
    assert t["w_M"][1] == 2.5
    p2 = tmp_path / "t.txt"
    p2.write_text("iter phi_M w_M\n1 1.0 NaN\n")
    t2 = load_trace(p2)
    assert np.isnan(t2["w_M"][0])


def _relaxation_oscillation(n=600, seed=5):
    """Non-sinusoidal sustained oscillation with jittering period 15..25."""
    rng = np.random.default_rng(seed)
    phase = np.cumsum(2 * math.pi / rng.uniform(15, 25, n))
    x = 20 + 15 * np.tanh(3 * np.sin(phase)) + 0.3 * rng.standard_normal(n)
    y = 300 - 80 * np.tanh(3 * np.sin(phase + 0.7))
    return np.column_stack([x, y])


def test_nonlinear_sustained_oscillation_is_not_contractive():
    """Real T-0003 traces at D>=2000 look like this: the linear fit is poor."""
    s = estimate_spectrum(_relaxation_oscillation())
    assert s.regime == "limit-cycle"
    assert s.nonlinear
    assert s.period is not None and 14 <= s.period <= 26
    xs = _relaxation_oscillation()
    findings = diagnose({"a": xs[:, 0], "b": xs[:, 1]})
    osc = [f for f in findings if f.name == "oscillation"]
    assert osc and osc[0].severity == "error"


def test_decaying_oscillation_is_contractive_info():
    xs = _linear_iterates([0.8 * complex(math.cos(1.5), math.sin(1.5)), 0.1])
    findings = diagnose({"a": xs[:, 0], "b": xs[:, 1]})
    assert [f.name for f in findings] == ["contractive"]


def test_collapse_earlier_in_trace_is_still_flagged():
    """D-stepping without averaging: phi_M collapses at D~1400 and stays near 0."""
    phi = np.concatenate([np.linspace(9.0, 11.0, 400), np.full(600, 0.09)])
    f = check_collapse(phi)
    assert f is not None and f.name == "collapse-to-trivial"
    assert check_collapse(np.linspace(9.0, 13.0, 1000)) is None


def test_large_oscillation_is_not_a_collapse():
    """T-0003 at D=5000: phi_M swings 5..98; troughs are not a collapse."""
    xs = _relaxation_oscillation()
    assert check_collapse(xs[:, 0]) is None
    assert check_collapse(np.abs(xs[:, 0] - 20)) is None


def test_collapse_with_transient_after_drop():
    """Brief spikes right after the drop, then the trivial solution."""
    phi = np.concatenate([np.linspace(9.0, 11.0, 400), [3.0, 6.5, 1.0, 5.8, 0.4],
                          np.full(600, 0.09)])
    assert check_collapse(phi) is not None


# --- T-0014: lessons from the T-0012 pilot (arm B) ---------------------------

def test_magnitude_only_observables_are_flagged():
    """max|field| hides the sign of an alternating mode (pilot: -9.3 read as +2.1)."""
    n = np.arange(8)
    signed = 1e-3 * (-9.3) ** n            # alternating, divergent, around a zero fixed point
    mags = np.column_stack([np.abs(signed), 3 * np.abs(signed)])
    findings = diagnose({"phiM": mags[:, 0], "omgM": mags[:, 1]})
    names = [f.name for f in findings]
    assert "sign-ambiguous" in names
    assert "short-trace" in names
    # a signed observable removes the ambiguity and gives the right sign
    findings = diagnose({"phiM": mags[:, 0], "phiMid": signed})
    assert "sign-ambiguous" not in [f.name for f in findings]
    s = estimate_spectrum(signed[:, None])
    assert s.eigenvalue.real == pytest.approx(-9.3, rel=0.02)


def test_empirical_rate_finite_on_exact_convergence():
    """Traces printed with few digits contain repeated rows (zero increments)."""
    x = np.round(5 + 0.8 ** np.arange(60), 4)
    s = estimate_spectrum(x[:, None])
    assert math.isfinite(s.empirical_rate) and s.empirical_rate < 2


def test_optimal_relaxation_reported_for_real_negative_mode():
    """Pilot arm B: lambda ~ -9.3 on the wall vorticity -> xi = lambda/(lambda-1) ~ 0.9."""
    xs = _linear_iterates([-9.3, 0.1], n_iter=12)
    findings = diagnose({"a": xs[:, 0], "b": xs[:, 1]})
    osc = [f for f in findings if f.name == "oscillation"]
    assert osc
    assert osc[0].data["optimal_xi"] == pytest.approx(9.3 / 10.3, abs=0.01)
    assert "0.90" in osc[0].message
    assert "nonlinear-gauss-seidel" in osc[0].skills      # |lambda| >> 1: strong coupling
