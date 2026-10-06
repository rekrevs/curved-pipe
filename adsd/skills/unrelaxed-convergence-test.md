# Skill: unrelaxed convergence test

**Diagnosis that calls for it:** `false-convergence-risk` or `false-convergence`
from `python -m adsd.probes`. The symptom is heavy under-relaxation that
"converges" quickly, often to a near-trivial solution, while the equation
residual stays large.

## Mechanism

With under-relaxation `x_relaxed = xi*x_old + (1-xi)*x_raw`, the increment is

    |x_old - x_relaxed| = (1-xi) * |x_old - x_raw|

A test `|x_old - x_relaxed| < eps` therefore accepts raw updates up to
`eps/(1-xi)`. At xi = 0.9 that is 10x eps. Increasing damping to fight an
oscillation silently switches the convergence test off.

The same bug appears wherever a *smoothed* quantity is tested. One example is
a correction updated as `C <- C + omega1*(C_new - C)`: testing
`omega1*|C_new - C|` instead of `|C_new - C|`.

## Implementation

```fortran
! after: ARR(:,:,3) = XI*ARR(:,:,1) + XIC*ARR(:,:,3)   (XIC = 1-XI)
IF (ABS(ARR(I,J,1) - ARR(I,J,3)) > XIC*EPS) ICV = 1    ! not "> EPS"
! smoothed corrections: test the undamped change
IF (MAXVAL(ABS(C0_NEW - C0)) > CORR_TOL) CORR_CONVERGED = .FALSE.
```

Also test the **equation residual** (or a boundary-condition residual such as
`|omega_wall + 2 phi_NR / h^2|`), not only the increment.

## Pitfalls

- Fixing the test makes heavily damped runs slow, because they now have to
  actually converge. That is correct. The cure for the underlying
  oscillation is a different skill (two-cycle averaging or Anderson).
- Heavy damping by itself pushes eigenvalues towards +1 (`lambda -> xi +
  (1-xi)*lambda`). The result can be a slow, large-amplitude limit cycle.
  Before this fix, the C&D solver at D >= 2000 cycled with period 17–47
  (`docs/adsd/probe-validation.md`, H1).

## Evidence

- T-0001 (commit `271219f`): with XI(3) = 0.9 or 0.95, D = 2000 "converged" to
  phi_M = 0.04 against the target 13.38 (`docs/attempts.md`). After the fix,
  heavy damping no longer gives false convergence.
- Pre-T-0005: the correction loop tested `omega1*|dC0|`, 20x smaller than the
  true change at omega1 = 0.05 (`docs/still-struggling.md`). This is the
  **same bug class a second time**: the lesson had been retained as a fix,
  not as a probe.
