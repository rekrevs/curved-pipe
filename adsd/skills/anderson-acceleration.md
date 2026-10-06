# Skill: Anderson acceleration of the outer fixed-point iteration

**Diagnosis that calls for it:** any of the following from
`python -m adsd.probes`:

- `slow-monotone`: dominant real eigenvalue close to +1, where averaging and
  damping make things slower.
- `oscillation`, when averaging alone leaves `|(1+lambda)/2|` ≥ 0.95.
- `divergent`.
- `collapse-to-trivial`: Picard leaves the basin of the nontrivial solution.

The symptom is that adding a source or correction term beyond a small fraction
destabilises an iteration that was otherwise fine.

## Mechanism

Keep the last m+1 pairs `(T(x_k), f_k = T(x_k) - x_k)`. Choose weights
`alpha` with `sum(alpha) = 1` that minimise `|| sum alpha_k f_k ||`, and step
to `sum alpha_k T(x_k)`, damped by beta towards the newest `T(x)`. This is
equivalent to GMRES on the linearised residual, so it can converge to fixed
points where Picard iteration is unstable.

## Implementation

Use `fortran/anderson_mod.f90`. It is a standalone module with a test,
`fortran/test_anderson.f90`, in which Picard diverges (residual 4.5 → 1.2e8)
and Anderson converges to 1e-10:

```fortran
USE ANDERSON_MOD
TYPE(AA_STATE) :: aa
CALL AA_INIT(aa, n, depth=4, beta=0.5_dp, wts=w)   ! w: 1/max|field| per component
DO
  CALL PACK_STATE(x)        ! flatten all coupled fields into one vector
  CALL OUTER_ITERATION()    ! one Picard sweep: x -> T(x)
  CALL PACK_STATE(gx)
  CALL AA_STEP(aa, x, gx, xnew)
  CALL UNPACK_STATE(xnew)   ! then re-impose hard boundary conditions
END DO
CALL AA_RESET(aa)           ! whenever the map changes (new corrections, new D)
```

Settings that worked on the Dean-flow solver: depth 4, beta 0.5,
regularisation 1e-12 · max diag, restart when `max|alpha| > 10`, per-field
weights `1/max(1, max|field|)`.

## Pitfalls

- **Reset the history whenever the map changes**, e.g. after a
  deferred-correction update or a continuation step. Mixing iterates of
  different maps is meaningless.
- Weight the inner product. Otherwise the field with the largest magnitude
  (vorticity, O(10³)) dominates the least-squares problem.
- Re-impose hard boundary conditions after the step, since a linear
  combination of iterates can violate them slightly.
- Combine it with two-cycle averaging inside T if the raw map oscillates.
  The C&D solver applies averaging first, then Anderson.

## Evidence

- T-0005 (commit `72e7773`): at D = 5000, Picard with every damping variant
  (v1–v12, `docs/still-struggling.md`) could absorb only about 8% of the Fox
  correction before NaN or collapse (best w_M 434.0 against 449.3). With
  Anderson, all 692 correction iterations stayed stable, giving w_M = 449.37
  (0.02% from C&D).
- Literature pointer in the project notes: Pollock et al. (2019), Anderson
  acceleration for Navier–Stokes Picard iteration at high Reynolds number.
