# Skill: deferred-correction consistency check

**Diagnosis that calls for it:** a deferred-correction run (for example
upwind iterated, central accuracy targeted) converges, but its values do not
approach the reference, or the "corrected" solution is not second-order.

## Mechanism

In Fox's deferred correction (Collins & Dennis 1975, eqs. 13 and 17), the
stable low-order (upwind) solver is iterated with a frozen correction term
added as a source. For convection-diffusion with upwind coefficients:

    C_0(i,j) = -(1/2r) [ |DELTA| (W_E + W_W - 2 W_0) + |GAMMA| (W_N + W_S - 2 W_0) ]

Here |DELTA| and |GAMMA| are the magnitudes of the convective coefficients
in the r and alpha directions. Upwind plus C_0 equals the central-difference
operator exactly. At convergence of both levels, the solution therefore
satisfies the **central** equations.

That gives a direct probe: compute the residual of the *target* (central)
discretisation on the converged solution. It must go to zero as the
corrections converge. If it does not, the correction formula, its sign, its
normalisation (division by the diagonal), or a stencil is wrong.

## Implementation

1. **Algebraic check, before any solver run.** For random fields `W`, verify
   `upwind_operator(W) + C_0(W) == central_operator(W)` to round-off at
   interior points. The project's version is `verify_fox.py`.
2. **Runtime check.** After each correction pass, compute
   `max|central_residual|` for each field (`CHECK_CENTRAL_RESIDUALS` in the
   C&D solver) and log it. It should decrease geometrically with the
   correction iterations.
3. Update corrections with smoothing,
   `C <- omega1*C_new + (1-omega1)*C`, and test convergence on
   `|C_new - C|`, not on the smoothed change (see
   `unrelaxed-convergence-test.md`).

## Pitfalls

- Every equation in the coupled system needs its own correction. In the
  Dean-flow problem the W and Omega equations need corrections (C_0, E_0);
  the stream-function Poisson equation was made central directly.
- Corrections change the fixed-point map. Reset any acceleration history
  when they are updated.
- At high parameter values, applying the full correction at once can push
  Picard iteration out of its basin. Use small omega1 plus Anderson
  acceleration.

## Evidence

- Step 0 (commit `7a0279f`, `docs/attempts.md` Round 1): asymmetric
  (1/r)∂φ/∂r stencil, special-cased wall row, missing Dirichlet enforcement.
  These were found by checking against the central equations. After fixing
  them, D ≤ 1000 matched C&D to 4 significant figures.
