# Skill: parameter continuation with a consistent handoff

**Diagnosis that calls for it:** `collapse-to-trivial` or `divergent` at the
start of a new parameter value. Other symptoms: a hard case that fails from a
cold start but works when reached in small parameter steps, or a crash
right after switching from one case to the next.

## Mechanism

For a strongly nonlinear problem (here the Dean number D), the basin of
attraction of the nontrivial solution shrinks as the parameter grows.
Continuation walks the parameter in small steps, using each solution as the
initial guess for the next.

**The state handed over must be consistent with the operator at the start of
the next phase.** If the next phase resets auxiliary terms (deferred
corrections, lagged sources) to zero, the handed-over fields must be the
ones that were converged *with those terms at zero*.

## Implementation

```fortran
! after converging case k (before corrections are applied):
PHI_UNCORR = PHI; W_UNCORR = W; OMEGA_UNCORR = OMEGA
! ... corrections iterate, final corrected solution reported ...
! start of case k+1 (corrections reset to 0 for the continuation phase):
PHI = PHI_UNCORR; W = W_UNCORR; OMEGA = OMEGA_UNCORR
D = D_prev
DO WHILE (D < D_target)
  D = MIN(D + D_STEP, D_target)
  DO it = 1, STEP_ITERS          ! a few outer iterations per step, no full convergence
    CALL OUTER_ITERATION()        ! with the same stabiliser (averaging) as at the target
  END DO
END DO
! full convergence only at D_target
```

Reasonable starting values: steps of about 1% of the parameter, 20–40 outer
iterations per step, smaller steps on finer grids.

## Pitfalls

- Stabilisers must also be active *during* stepping. On the C&D solver,
  collapse happened during stepping at D ≈ 1420, well before the target
  D = 2000 (`docs/adsd/probe-validation.md`, H2).
- Warm-starting the *corrections* from the previous case is a separate
  choice and gave mixed results: D = 2000 improved a lot, D = 3500 got worse
  (T-0003).

## Evidence

- T-0004: D = 5000 stepping crashed when it started from D = 3500's
  *corrected* fields with corrections reset to zero. Handing over the
  uncorrected fields fixed it.
- T-0003 (commit `6d19af9`): carrying corrections between cases took D = 2000
  phi_M from 3.10 to 15.44 (target 13.38) but D = 3500 from 12.59 to 49.33
  (target 17.13).
