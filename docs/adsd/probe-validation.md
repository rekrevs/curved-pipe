# Probe validation on real solver traces (T-0011)

ADSD (Chen & Yin 2026) keeps only those diagnostic hypotheses that are
validated on data. This note records how the `adsd` probes were checked
against this repository's own solver history and counterfactual runs. It also
records what the measurements say about the **retained knowledge** in
CLAUDE.md, which turned out to be partly wrong.

## Reproduce

```bash
python -m adsd.validation.solver_traces <workdir>            # history, stepping, fixed (~15 min)
python -m adsd.validation.solver_traces <workdir> gridc      # held-out grid (c) (~3 min)
python -m adsd.validation.analyze <workdir>                  # 19 checks, exit 0 = all pass
```

`solver_traces.py` builds each variant from a git revision of
`Collins_Dennis_1975_central.f90`. It adds a **trace-only** patch (one WRITE
per outer iteration), plus switches for 2-cycle averaging, the D of case 8,
MAXOUT and the grid. Everything is compiled and run in the work directory,
so the repository solver is never modified. The averaging-on variant
reproduces the reference values exactly (D=2000: phi_M 13.3721, w_M 234.53),
which shows the instrumentation does not change the numerics.

## Results (grid (b) unless stated)

| Check | Data | Probe output | Verdict |
|-------|------|--------------|---------|
| H1 | T-0003 state (`6d19af9`), D ≤ 1000 (7 cases) | contractive | PASS |
| H1 | T-0003 state, D = 2000 / 3500 / 5000 | nonlinear limit cycle, period 17 / 31 / 47 | PASS |
| H2 | current solver, D-stepping 1000→2000, averaging **off** | collapse to trivial at D = 1420 (log said ≈1430) | PASS |
| H2 | same, averaging on | no collapse | PASS |
| H3 | fixed D = 1300, averaging off | λ ≈ 0.54+0.53i, \|λ\| 0.76, contractive | PASS |
| H3 | fixed D = 1400, averaging off | \|λ\| ≈ 1.02, divergent + collapse (φ_M → 0.086) | PASS |
| H3 | fixed D = 1300 / 1400, averaging on | λ ≈ 0.79+0.23i / 0.83+0.26i, contractive | PASS |
| H4 | averaging maps λ → (1+λ)/2 at D = 1300 | predicted 0.77+0.27i, measured 0.79+0.23i | PASS |
| H5 (held-out) | grid (c), D = 500, averaging off | **exact period-3 limit cycle**, λ = −0.500+0.866i, \|λ\| = 1.000, fit residual 0.00; averaging predicted to give 0.5 | PASS |
| H5 (held-out) | grid (c), D = 500, averaging on | contractive, \|λ\| 0.83 | PASS |

19/19 checks pass. Synthetic tests: `python -m pytest adsd/tests` (19 pass).

## What this says about the retained knowledge

1. **"2-cycle averaging kills the period-2 oscillation (λ ≈ −1)"** (CLAUDE.md,
   T-0004) is **not** what happens on grid (b). The instability that
   averaging cures there is a **complex pair at roughly ±45°** (period ≈ 8).
   It crosses \|λ\| = 1 between D = 1300 and D = 1400 and then collapses to the
   trivial solution. Averaging works because (1+λ)/2 pulls *any* eigenvalue
   with \|λ\| ≈ 1 inside the unit disk, except those near +1. No period-2
   mode was observed in any trace.
2. **"Grid (c) has period-3 oscillation at D ≥ 500"** (T-0004) is
   **confirmed exactly** on held-out data. Averaging maps it to 0.5.
3. **The T-0003 limit cycle at D ≥ 2000** (heavily damped XI = 0.85–0.95) was
   a slow nonlinear relaxation oscillation with period 17–47, not a 2-cycle.
   Heavy under-relaxation pushes eigenvalues towards +1, which slows
   the cycle down without removing it. T-0004 reset XI to 0.5/0.1 *and* added
   averaging, so the dev-logs credit averaging with a change that also
   included removing over-damping.
4. **NaN masking** (CLAUDE.md gotcha #1, "MAX(a, NaN) = a") is
   flag-dependent. `fortran/nan_max_probe.f90` with GNU Fortran 16.2 shows
   that `MAX` and `MAXVAL` hide NaN at all levels, while a running
   `m = MAX(m, x)` returns NaN at -O2/-O3 and hides it at -O0.

## Caveats

- **Tuning vs. validation.** H1–H4 were run while the probes were being
  developed. The collapse rule was revised twice on these traces (to ignore
  oscillation troughs and to tolerate transients after a drop). Only H5
  (grid c) and the synthetic tests are clean out-of-sample checks.
- **Linear fits on raw grid (b) traces are poor** (relative residual
  0.6–0.9). The modulus is consistent across windows, but the angle at
  D = 1400 depends on the window: 45° over iterations 5–65, 120° over 5–125.
  The on/off consistency at D = 1300 (H4) is the strongest evidence for the
  complex-pair picture.
- The D = 5000 T-0003 trace also triggers `collapse-to-trivial`, because the
  trace ends in a deep trough of the oscillation. This is a known false
  positive. The `oscillation` finding is correct.
- **Unexplained side observation.** At fixed D = 1300 the final corrected
  solution differs between averaging on/off (φ_M 10.67 against 10.49). In the
  grid (c) run, D = 250 differs by 0.4%. A fixed point of the averaged map is
  a fixed point of the raw map, so the difference most likely comes from
  different stopping (convergence test and number of correction passes),
  not from different fixed points. This was not investigated further.
