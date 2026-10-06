# Skill: nonlinear Gauss–Seidel outer iteration (one sweep per field)

**Diagnosis that calls for it:** the outer iteration of a coupled
multi-field solver needs heavy stabilisation. Typical signs:

- averaging weights well below 0.5,
- Anderson stalling or restarting,
- a block-Picard dominant eigenvalue far outside the unit circle (|λ| ≫ 1,
  e.g. −4 to −9),

when each outer iteration solves every field **to convergence** with the
other fields frozen.

*Retained from:* the T-0012 pilot, arm B (`docs/adsd/pilot.md`). A fresh
agent found it beyond the original library.

## Mechanism

**Block Picard.** Each field is solved fully, `PHI ← solve(OMEGA)`, then
`W ← solve(PHI)`, then `OMEGA ← solve(W, PHI)`. Every block responds with
its full gain to the change in the others. With a strongly amplifying
coupling, such as the Thom wall vorticity `ω_w = −2φ/h²` (gain ∝ 2/h²), the
loop gain of the coupled map is large and alternating.

**Nonlinear Gauss–Seidel (NLGS).** Do one relaxation sweep per field per
outer iteration and keep the coupling explicit. Each field moves only part
of the way before the others react, as in pseudo-time stepping. Inner and
outer convergence happen together, and the coupled map becomes a
contraction without extra stabilisers.

## Implementation

```fortran
DO it = 1, MAXIT
  CALL SOR_SWEEP_PHI(1)            ! ONE sweep, not "until converged"
  CALL APPLY_WALL_BC(xi_wall)      ! relaxed wall vorticity (see below)
  CALL SOR_SWEEP_W(1)
  CALL SOR_SWEEP_OMEGA(1)
  IF (max relative change of all fields < tol) EXIT
END DO
```

- Use **ρ = 1 (Gauss–Seidel)** for the convection-dominated, non-symmetric
  upwind W/Ω operators. Over-relaxation (ρ = 1.5) blew up to Inf after a few
  outer steps in the pilot. ρ ≈ 1.6 is fine for the symmetric PHI Poisson
  equation.
- **Relax the strongly amplifying boundary coupling** with the weight that
  cancels its measured eigenvalue. Relaxation `x ← ξ x + (1−ξ) T(x)` maps
  λ → ξ + (1−ξ)λ, which is zero at **ξ = λ/(λ−1)**. In the pilot,
  λ ≈ −9.3 gave ξ_wall ≈ 0.9. `python -m adsd.probes` reports this ξ
  for real negative modes.
- **Deferred correction.** Freeze the corrections, run NLGS to tolerance,
  update the corrections, and repeat. Tie the inner tolerance to the size of
  the last correction change (inexact inner solves) to save time.

## Pitfalls

- Do not stack Anderson on top of NLGS by default. In the pilot it *stalled*
  the already-contractive iteration.
- Judge convergence on the unrelaxed per-iteration change and on the
  target-scheme residual, since each NLGS step is small
  (`unrelaxed-convergence-test.md`, `deferred-correction-consistency.md`).

## Evidence

- Pilot arm B, D = 5000 fixed-D tests:
  - Block Picard with averaging and Anderson needed averaging weight
    θ ≈ 0.125 and still limit-cycled at correction level 11. The block-Picard
    eigenvalue was about −4 to −7.
  - NLGS converged with no averaging and no Anderson: the probe showed a
    contractive complex mode with |λ| ≈ 0.45.
- Final solver: all 7 Dean numbers converge, including the **full** Fox
  correction at D = 5000 on grid (b) (w_M = 443.99). Runtime 8.5 s, against
  93 s for the independently tuned block-Picard solver of arm A, which gives
  the same values to every printed digit.
- `docs/adsd/pilot-artifacts/armB-REPORT.md`, `armB-solver.f90`.
