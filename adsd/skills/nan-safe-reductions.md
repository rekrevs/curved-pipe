# Skill: NaN-safe reductions and divergence guards

**Diagnosis that calls for it:** `non-finite` or `masked-nan-suspect` from
`python -m adsd.probes`. The symptom is a run that "converges" suddenly
with reported maxima of exactly 0, or convergence tests that pass on a
diverged field.

## Mechanism

IEEE NaN compares false with everything, and Fortran reductions handle it
inconsistently. Measured with GNU Fortran 16.2 by `fortran/nan_max_probe.f90`,
using VOLATILE values so nothing is constant-folded:

| expression | -O0 | -O2/-O3 |
|------------|-----|---------|
| `MAX(1, NaN)`, `MAX(NaN, 1)` | 1 | 1 |
| `m=0; m=MAX(m, NaN)` (running max) | 0 | NaN |
| `MAXVAL([1, NaN, 2])` | 2 | 2 |
| `NaN > 0` | F | F |
| `SUM([1, NaN, 2])` | NaN | NaN |

A convergence test of the form `MAXVAL(ABS(new-old)) < EPS` therefore
*passes* on a field full of NaN. A peak search with `IF (x > xmax)` reports 0.
Whether a running `MAX` hides NaN depends on the optimisation level.

## Implementation

```fortran
USE, INTRINSIC :: IEEE_ARITHMETIC, ONLY: IEEE_IS_FINITE
! inside each inner solver, once per sweep:
IF (.NOT. ALL(IEEE_IS_FINITE(X(2:NR,2:NA,3)))) THEN
  FAILED = .TRUE.; RETURN          ! abort, restore last good state upstream
END IF
! cheap global check after an outer iteration (SUM propagates NaN):
S = SUM(ABS(PHI(:,:,3))) + SUM(ABS(W(:,:,3))) + SUM(ABS(OMEGA(:,:,3)))
IF (S /= S) THEN ... ! NaN
```

Combine this with collapse detection. If the peak value drops below 50% of
the previous pass, restore the last good state.

## Pitfalls

- Run `nan_max_probe.f90` for your compiler and flags. Do not rely on a
  remembered rule.
- Check boundary rows as well. In T-0005 a restart produced NaN at boundary
  points that interior-only checks missed.

## Evidence

- `docs/still-struggling.md` (T-0005): diverged SOR made the correction
  residuals appear to be 0, convergence "succeeded", and the run reported
  phi_M = w_M = 0. After `IEEE_IS_FINITE` guards in SOR_PHI, SOR_W,
  SOR_OMEGA and SMOOTH, NaN is detected at its source.
