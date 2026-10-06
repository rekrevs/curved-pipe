# adsd: diagnostic probes and retained skills for iterative solvers

A small library in the spirit of **ADSD**: *Training Numerical Intelligence via
Auto-Diagnosis and Skill Discovery* (Chen & Yin, arXiv:2610.03872, 2026).
Diagnose *why* a fixed-point or outer iteration fails, then apply a remedy
that has been retained with its evidence.

Everything here was extracted from the Collins & Dennis (1975) Dean-flow
reconstruction in this repository. See `docs/adsd/retrospective.md` for the
history and `docs/adsd/probe-validation.md` for the validation.

## 1. Produce a trace

Write one row per outer iteration with a header. CSV or whitespace-separated
both work, and Fortran `NaN` / `Infinity` tokens are accepted. Use any
quantities that see the dominant mode: field maxima, values at a few fixed
grid points, max|update|, residual norms.

```fortran
OPEN(77, FILE='trace.csv', STATUS='REPLACE')
WRITE(77,'(A)') 'iter,phiM,wM,omgM,phiMid,dphi'
! once per outer iteration, at a FIXED parameter value:
WRITE(77,'(I6,5(",",ES16.8))') IOUT, MAXVAL(ABS(PHI(:,:,3))), MAXVAL(ABS(W(:,:,3))), &
     MAXVAL(ABS(OMEGA(:,:,3))), PHI(NR/2,NA/2,3), MAXVAL(ABS(PHI(:,:,3)-PHI(:,:,1)))
```

Spectral estimates need a stationary map, so trace at a fixed parameter value.
During continuation steps the map changes every few iterations.

## 2. Diagnose

```bash
python -m adsd.probes trace.csv --state phiM,wM,omgM,phiMid
python -m adsd.probes trace.csv --xi 0.9          # also check a relaxed convergence test
python -m adsd.probes trace.csv --step dphi --residual res --step-tol 1e-6 --res-tol 1e-3
python -m adsd.probes trace.csv --json
```

Exit code 1 means at least one error-level finding.

| Probe | Finding | Meaning |
|-------|---------|---------|
| `estimate_spectrum` | `oscillation`, `slow-monotone`, `divergent`, `contractive` | Dominant eigenvalue λ of the outer map (vector Prony on successive differences), its period, and \|(1+λ)/2\|. Falls back to an amplitude analysis (`nonlinear=True`) when the linear fit is poor |
| `check_false_convergence` | `false-convergence(-risk)` | Increments small but residual large, or a test on a relaxed increment (tolerance inflated by 1/(1−ξ)) |
| `check_nonfinite` | `non-finite`, `masked-nan-suspect` | NaN/Inf, or an O(1) maximum that suddenly becomes exactly 0 |
| `check_collapse` | `collapse-to-trivial` | A plateaued magnitude drops below 50% and stays down |

## 3. Apply the skill

| Skill | Called for by |
|-------|---------------|
| [`skills/unrelaxed-convergence-test.md`](skills/unrelaxed-convergence-test.md) | false convergence |
| [`skills/two-cycle-averaging.md`](skills/two-cycle-averaging.md) | oscillation with \|(1+λ)/2\| < \|λ\| |
| [`skills/anderson-acceleration.md`](skills/anderson-acceleration.md) + [`skills/fortran/anderson_mod.f90`](skills/fortran/anderson_mod.f90) | slow-monotone, divergent, collapse, or oscillation that averaging alone does not fix |
| [`skills/continuation-handoff.md`](skills/continuation-handoff.md) | collapse or divergence at the start of a parameter value |
| [`skills/nan-safe-reductions.md`](skills/nan-safe-reductions.md) + [`skills/fortran/nan_max_probe.f90`](skills/fortran/nan_max_probe.f90) | non-finite, masked NaN |
| [`skills/deferred-correction-consistency.md`](skills/deferred-correction-consistency.md) | deferred correction converges to the wrong values |

Each skill file lists its trigger, mechanism, implementation, pitfalls and the
evidence it rests on.

## Tests

```bash
python -m pytest adsd/tests -q                              # probes on known spectra
cd adsd/skills/fortran && gfortran -O2 -o /tmp/t anderson_mod.f90 test_anderson.f90 && /tmp/t
gfortran -O2 -o /tmp/n adsd/skills/fortran/nan_max_probe.f90 && /tmp/n
python -m adsd.validation.analyze <workdir>                 # real-trace validation
```
