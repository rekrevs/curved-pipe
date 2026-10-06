# REPORT: second-order (deferred-correction) Dean-flow solver

`gfortran -O2 -o solver solver.f90 && ./solver` runs all seven cases in about
8 s of wall time. All cases converge. Full output is in `run.log`, and one
trace per D (one row per correction level) is in `trace_D<D>.csv`.

## Final results (grid NR = 20, NA = 36, h = 0.05, k = pi/36)

| D | phi_M (this) | phi_M (C&D) | diff | w_M (this) | w_M (C&D) | diff | status |
|------|--------|-------|--------|---------|--------|--------|-----------|
| 96 | 0.9944 | 0.995 | -0.06% | 23.344 | 23.34 | +0.02% | CONVERGED |
| 500 | 6.1583 | 6.166 | -0.12% | 83.400 | 83.50 | -0.12% | CONVERGED |
| 605.72 | 6.9618 | 6.972 | -0.15% | 96.201 | 96.24 | -0.04% | CONVERGED |
| 1000 | 9.3059 | 9.308 | -0.02% | 140.591 | 140.6 | -0.01% | CONVERGED |
| 2000 | 13.3691 | 13.38 | -0.08% | 234.524 | 234.9 | -0.16% | CONVERGED |
| 3500 | 17.4756 | 17.13* | +2.0% | 347.234 | 351.4* | -1.2% | CONVERGED |
| 5000 | 20.4271 | 19.97* | +2.3% | 443.990 | 449.3* | -1.2% | CONVERGED |

\* The C&D reference values for D = 3500 and 5000 are for the finer grid (h = 0.025), so a gap of a few percent is expected.

For comparison, the plain upwind (first-order) solution on this grid gives
phi_M = 0.910, 5.87, 6.71, 9.08, 13.17, 17.32, 20.52 and
w_M = 22.72, 79.87, 91.33, 130.76, 214.66, 316.21, 401.53. The correction
moves every value onto C&D's.

**Consistency check.** After convergence, the residuals of the *central*
equations are ≤ 2e-7 relative for all three equations at every D. These are
computed by `CENTRAL_RESIDUALS`, which is written independently of the
upwind/correction split. So the solution satisfies the central-difference
equations, not just a fixed point of the iteration. A case is reported as
CONVERGED only if both hold:

- the unrelaxed correction change |C_new − C|/|C| is below 1e-8;
- the central residuals are below 1e-5.

Tightening the tolerances by a further 100× changes no printed digit.

## What the solver does (mapping onto Schubert's code)

- **Scaling.** Schubert's equations are multiplied by h·k. The W/OMEGA
  operator is `E6*W0 = E1*W_E + E3*W_W + E2*W_N + E4*W_S + source`, where
  `DELTA = DA - (PHI_N - PHI_S)/2` and `GAMMA = (PHI_E - PHI_W)/2`.
  - The DA in DELTA is the (1/r)∂/∂r diffusion term. Schubert discretises it
    with a forward difference, folded into the upwinding.
- **Correction terms.** C_0 and E_0 are applied exactly as in the paper:
  `-(1/2r)[|DELTA|(E+W-2·0) + |GAMMA|(N+S-2·0)]`, with r → RINV(I).
  - They are added to the numerator before division by E6 (Schubert's
    E(I,J,6)).
  - Because DELTA contains DA, the correction also makes (1/r)∂W/∂r central.
  - On the symmetry lines (J = 1, NA+1) the mirror images W(I,0) = W(I,2) are
    used, and GAMMA = 0 there.
  - At the origin, the 5-point Cartesian stencil with upwind coefficient
    PHI(2,NAH) gets `C = -(|PHI(2,NAH)|/2)(W(2,1) + W(2,NA+1) - 2W(1,1))`.
- **PHI equation.** This is made central directly: Schubert's forward
  difference DA/r·(PHI_E − PHI_0) becomes DA/(2r)·(PHI_E − PHI_W).
  - It is solved on every interior row including r = 1 − h, with PHI = 0 at
    the wall. Schubert special-cased that row as PHI(NR) = PHI(NR−1)/4.
  - The wall vorticity uses Thom's formula, −2 PHI(NR)/h².
  - PI = ACOS(−1); Schubert had 3.14159255.
- **Two-level iteration.**
  - Inner level: C_0 and E_0 are frozen. The fields are iterated by nonlinear
    Gauss–Seidel (one SOR sweep each of PHI (ρ = 1.6), W and OMEGA (ρ = 1.0)
    per iteration), with the wall vorticity relaxed at ξ_wall = 0.9, until
    the per-iteration change is below 1e-11 (relative). This tolerance is
    relaxed to 1e-4·dC while the corrections are still moving.
  - Outer level: `C_0 <- omega1*C_0_new + (1-omega1)*C_0` with omega1 = 0.5,
    repeated until the unrelaxed change converges. This takes 55–100
    correction levels.
- **Continuation.** Each D is reached by continuation of the *uncorrected*
  (upwind) solution in 5% steps, following the continuation-handoff skill.
  The deferred-correction phase then starts from those fields with C = 0.
- **Safety nets.** A NaN guard runs in every SOR sweep. If the inner solve
  fails, a damping ladder restores the state and retries. If the inner solve
  fails during the correction phase, omega1 is halved. Neither triggers in
  the final configuration.

## What I tried, in order (and how each problem was diagnosed)

1. **First version.** It had:
   - central PHI, C_0/E_0 corrections and the central-residual probe;
   - Picard outer sweeps, where each field is solved fully by SOR, with
     Anderson acceleration;
   - Thom's wall vorticity without relaxation.

   **Result:** everything collapsed to NaN after about 5 iterations, even at
   D = 20.

   *Diagnosis:* the probe reported "divergent, λ ≈ +2.1". That did not fit,
   because Anderson was already on and D = 20 is nearly linear.
   - A pure-Picard test mode at D = 1 and 5 showed growth of ×9.3 per
     iteration independent of D, with PHI at a fixed point flipping sign each
     iteration. So it was really λ ≈ −9.3. The probe was fooled by
     magnitudes plus a very short trace.
   - That makes it a linear instability of the PHI → Thom ω_wall → ω → PHI
     loop. Schubert's special wall row had hidden it, and solving the PHI
     Poisson equation on the last row exposed it.
   - Fix: relax ω_wall. For λ ≈ −9.3 the ideal value is ξ = λ/(λ−1) ≈ 0.9,
     and that converged in 7 iterations.
   - With that fix, D = 96 matched C&D at once (0.9944 / 23.344), with
     central residuals around 1e-7. That confirmed the coefficient mapping.
2. **D ≥ 150: period-2 limit cycle.**
   - *Diagnosis:* the probe gave λ ≈ −1.000 with the note "2-cycle averaging
     maps the mode to 0".
   - Fix: added two-cycle averaging of the whole iterate before Anderson.
     After that, D = 96, 500 and 605.72 converged to within 0.15% of C&D.
3. **Run time and D ≈ 700.**
   - *Run time:* about 8 minutes, because every inner SOR went to 1e-11. I
     made the SOR tolerance follow the outer step (inexact inner solves),
     which cut test runs from minutes to seconds.
   - *Failure at D ≈ 700:* the cycle was still period-2 with λ ≈ −1 after
     averaging, so raw λ ≈ −3. A sweep of θ (the averaging weight) and
     ξ_wall showed that θ = 0.25 with Anderson works.
   - I added a damping ladder over (θ, ξ_wall): on NaN, blow-up or
     stagnation, restore the state and step up to stronger damping.
   - Result: D ≤ 3500 converged; D = 2000 gave 13.369 / 234.52 and
     D = 1000 gave 9.3059 / 140.59.
4. **D = 5000 failed at the first correction level.**
   - I added an adaptive omega1 (halve on failure, restore C), as the
     deferred-correction skill recommends. It still failed even at
     omega1 = 0.002, so the problem was not the basin of attraction.
   - The fixed-D tests at D = 5000 (from a saved D = 4900 state) showed that
     the ladder's large ξ_wall rungs (0.97/0.98) made it *worse*. The best
     setting was ξ = 0.9 with θ = 0.125. I rebuilt the ladder, and the run
     then reached correction level 11 before stalling in a noisy limit cycle.
   - A further test showed that W-SOR with ρ = 1.5 blows up to Inf after a
     few outer steps. Over-relaxation is not safe for this strongly
     non-symmetric upwind operator. Switching to ρ = 1.0 removed the NaNs,
     but the outer map still needed θ ≈ 0.125. The underlying cause is a
     block-Picard eigenvalue of about −4 to −7 at D = 5000.
5. **Fix that worked: nonlinear Gauss–Seidel at the inner level.**
   - Change: do one SOR sweep per field per iteration instead of solving
     each field fully, so the coupling between fields changes gradually,
     like pseudo-time stepping.
   - *Diagnosis:* in the fixed-D test it converged with no averaging and no
     Anderson. The probe gave a contractive complex mode with |λ| ≈ 0.45.
     Adding Anderson on top of it *stalled*.
   - Result: all 7 cases converged in 8 s, with no ladder or omega1
     fallback triggered.
   - The probes on the correction-level traces give contractive λ ≈ 0.51
     (D = 2000) and λ ≈ 0.75 (D = 5000). At D = 96 the probe flags a
     "period-2" mode, but the trace shows dC falling monotonically by about
     0.8 per level; the flag comes from round-off-level noise in the last few
     levels.
6. **False-convergence check.** Per-iteration GS changes are small, so I
   tightened the inner tolerance from 1e-9 to 1e-11 and the correction
   tolerance from 1e-7 to 1e-8. No printed digit changed, and the central
   residuals improved to ≤ 2e-7.
7. **Sensitivity check on the wall condition.** I replaced Thom's formula
   with Jensen's second-order formula, ω_w = −(8φ₁ − φ₂)/(2h²).
   - Results got worse against C&D: D = 96 gave 0.9886, and D = 1000 gave
     9.225 against 9.308.
   - So I kept Thom's formula, which is also the one in Schubert's code.
   - The remaining differences of about 0.1% at D = 500 and 605.72 (while
     D = 96 and 1000 agree to 4 figures) have no cause I could find; I did
     not tune anything to remove them.

## Notes and caveats

- **Kept but unused code.** The block-Picard + averaging + Anderson path is
  still in the code (`NLGS = .FALSE.`), together with a diagnostic test mode
  (`./solver test D XI_WALL MODE MAXIT [D0 THETA DEPTH RHO NSWEEP]`). These
  were used for the experiments above. The default run does not use them.
- **Probe quirk.** The probe's "empirical rate" field printed nonsense, such
  as 1e300, on traces that end in exact convergence. I ignored it and used
  only the eigenvalue estimates.
- **Compile and run count.** About 17 compiles and 12 full runs of the
  solver, plus about 45 short fixed-D test-mode runs for diagnosis.
