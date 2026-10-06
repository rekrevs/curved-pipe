# Skill: two-cycle averaging of the outer iterate

**Diagnosis that calls for it:** `oscillation` from `python -m adsd.probes`,
when the reported `|(1+lambda)/2|` is clearly below `|lambda|`. Typical
cases are a dominant eigenvalue near -1 (period 2), a complex pair at
±120° (period 3), or a complex pair at ±45° crossing `|lambda| = 1`. The
symptom is outer iteration oscillating or collapsing during parameter
continuation.

## Mechanism

Replace the fixed-point step `x <- T(x)` by

    x <- (x + T(x)) / 2

This keeps every fixed point and maps each eigenvalue of the linearised map
as `lambda -> (1 + lambda)/2`:

| raw lambda | after averaging | effect |
|-----------|-----------------|--------|
| -1 (period 2) | 0 | killed |
| exp(±2πi/3) (period 3) | 0.5 exp(±iπ/3) | modulus 0.5 |
| 1.03 exp(±iπ/4) (period ≈ 8, unstable) | ≈ 0.94 | stabilised |
| +0.97 (slow monotone) | 0.985 | **slower**: use Anderson instead |

It is under-relaxation with xi = 0.5 applied to the *whole coupled
iterate*, boundary values included, after all fields have been updated.
Per-field relaxation inside the sweep is not equivalent.

**Generalisation.** A weight ξ on the old iterate maps λ → ξ + (1−ξ)λ. For
a single real negative mode, the optimal weight is ξ = λ/(λ−1); the probe
reports it. If |λ| ≫ 1, look at the iteration structure before tuning weights
(`nonlinear-gauss-seidel.md`).

## Implementation

Keep the iterate from the start of the outer iteration (slice 1) and average
it with the end-of-iteration fields (slice 3) for **all** coupled fields,
including boundary values that are updated from interior values:

```fortran
IF (USE_AVG .AND. IOUT > 1) THEN
  PHI(2:NR,2:NA,3)    = 0.5_dp*(PHI(2:NR,2:NA,1)    + PHI(2:NR,2:NA,3))
  W(1:NR,1:NAP1,3)    = 0.5_dp*(W(1:NR,1:NAP1,1)    + W(1:NR,1:NAP1,3))
  OMEGA(2:NR,2:NA,3)  = 0.5_dp*(OMEGA(2:NR,2:NA,1)  + OMEGA(2:NR,2:NA,3))
  OMEGA(NRP1,2:NA,3)  = 0.5_dp*(OMEGA(NRP1,2:NA,1)  + OMEGA(NRP1,2:NA,3))  ! wall BC too
  ! convergence must now be judged on the averaged fields:
  ICV = 0
  IF (MAXVAL(ABS(PHI(2:NR,2:NA,1) - PHI(2:NR,2:NA,3))) > EPS_OUT(1)) ICV = 1
  ! ... same for W, OMEGA
END IF
```

Apply it during parameter continuation as well, not only at the target
parameter.

## Pitfalls

- Re-derive the convergence test after averaging. A test computed inside the
  field updates no longer sees the iterate actually kept.
- When fields and corrections are both iterated, the correction values can
  inherit the oscillation. Averaging the raw new correction with the
  previous raw one helped there (T-0004/T-0005).
- Thresholds do not transfer between grids. On the C&D problem the averaging
  was needed from D ≥ 2000 on grid (b) but from D ≥ 250 on grid (c). Use the
  probe to decide, not a remembered threshold.

## Evidence

- T-0004 (commit `4ed46cd`): with averaging (plus the XI table reset to 0.5),
  grid (b) D = 2000 converged to phi_M = 13.36 against C&D's 13.38. On grid
  (c), phi_M matched C&D at 3500 and 5000.
- `docs/adsd/probe-validation.md` (H2–H4) gives the **measured** mechanism on
  grid (b):
  - Without averaging, D-stepping collapses to the trivial solution at
    D ≈ 1420.
  - At fixed D = 1300, the raw dominant mode is λ ≈ 0.54+0.53i. Averaging
    measures 0.79+0.23i, while (1+λ)/2 predicts 0.77+0.27i.
  - At D = 1400, the raw mode has |λ| > 1 and averaging brings it to 0.87.
  - The dominant raw mode on grid (b) is a **complex pair**, not λ ≈ −1 as
    the project notes had assumed. Averaging works either way.
