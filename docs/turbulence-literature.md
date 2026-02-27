# Turbulent Dean Flow — Literature Review

*Generated 2026-02-25 as part of planning for T-0007/T-0008/T-0009.*

## Decision context

After completing the laminar Collins & Dennis (1975) solver (T-0001 through T-0005), the
next direction is a turbulent extension using a Van Driest algebraic mixing-length model.
This document records the literature search so future choices can be revisited.

---

## Laminar-turbulent transition in curved pipes

For Collins & Dennis curvature δ = a/R ≈ 0.05 (R/a ~ 20), Ito's (1959) empirical
criterion gives:

```
Re_c ≈ 2.1e4 × δ^0.45 ≈ 5040   →   De_c = Re_c × sqrt(δ) ≈ 1130
```

So the current laminar solver's D=5000 solutions are physically deep in the turbulent
regime — they represent the laminar branch, not the physical attractor.

**Flow-regime map (δ ≈ 0.05):**

| De range | Regime |
|---|---|
| < 75 | Laminar, no vortices |
| 75 – 400 | Laminar Dean vortex regime (current solver) |
| 400 – 1100 | Transitional (period-doubling, vortex instability) |
| > 1100 | Turbulent |

---

## Key papers

### Primary reference for implementation

**Patankar, S.V., Pratap, V.S., and Spalding, D.B. (1975).**
"Prediction of Turbulent Flow in Curved Pipes."
*Journal of Fluid Mechanics*, 67(3), 583–595.
[Cambridge Core](https://www.cambridge.org/core/journals/journal-of-fluid-mechanics/article/abs/prediction-of-turbulent-flow-in-curved-pipes/0CEEC4942E0F78234A2370D7A3D87541)

Uses k-ε (not mixing-length), but the curved-pipe RANS governing equations are derived in
the same φ/W/Ω spirit as Collins & Dennis. The mathematical setup (normalisations,
geometry, iteration) is the closest published analog to extending our solver. Start here
to understand how ν_T enters the W and OMEGA equations for curved-pipe fully-developed
flow.

### Best DNS validation data near transition

**Hüttl, T.J. and Friedrich, R. (2001).**
"Direct Numerical Simulation of Turbulent Flows in Curved and Helically Coiled Pipes."
*Computers & Fluids*, 30(5), 591–605.
[ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0045793001000081)

DNS at Re_τ = 230 (Re_bulk ≈ 5300), curvatures κ = 0, 0.01, 0.1. The κ=0 case provides
the straight-pipe log-law baseline for Phase 1 validation. The κ=0.1 case (De ≈ 1676 at
Re=5300) sits right at the edge of the turbulent regime and shows partial
relaminarization at the inner wall — highly relevant to Phase 3.

**Companion paper:** Hüttl & Friedrich (2000), *Int. J. Heat and Fluid Flow*, 21(3),
345–353 (torsion effects in helical pipes).

**Noorani, A., El Khoury, G.K., and Schlatter, P. (2013).**
"Evolution of Turbulence Characteristics from Straight to Curved Pipes."
*Int. J. Heat and Fluid Flow*, 41, 16–26.
[ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0142727X13000623)

DNS at Re_bulk = 5300 and 11700, κ = 0, 0.01, 0.1. Extends Hüttl & Friedrich to higher
Re. Full Reynolds-stress budgets reported. Use for Phase 3 mean-velocity profile
comparison at Re_bulk = 11700, κ = 0.01 (De ≈ 1240, well-turbulent, low curvature).

### Integral validation

**Ito, H. (1959).**
"Friction Factors for Turbulent Flow in Curved Pipes."
*ASME Journal of Basic Engineering*, 81(2), 123–132.
[ASME Digital Collection](https://asmedigitalcollection.asme.org/fluidsengineering/article-abstract/81/2/123/368890)

The standard experimental dataset for turbulent friction factor in curved pipes across a
wide range of Re and δ. Use the correlation f_c/f_0 as the primary integral validation
target for Phase 2. The transition criterion above also comes from this paper.

### Higher-Re experimental dataset

**Azzola, J., Humphrey, J.A.C., Iacovides, H., and Launder, B.E. (1986).**
"Developing Turbulent Flow in a U-Bend of Circular Cross-Section: Measurement and
Computation."
*ASME Journal of Fluids Engineering*, 108(2), 214–221.
[ASME](https://asmedigitalcollection.asme.org/fluidsengineering/article-abstract/108/2/214/409721)

Laser-Doppler anemometry at Re = 57,400 and 110,000 in a 180° U-bend. Good experimental
profiles for high-Re validation but developing flow (not fully developed). k-ε
computations included.

### LES reference

**Boersma, B.J. and Nieuwstadt, F.T.M. (1996).**
"Large-Eddy Simulation of Turbulent Flow in a Curved Pipe."
*ASME Journal of Fluids Engineering*, 118(2), 248–254.
[ASME](https://asmedigitalcollection.asme.org/fluidsengineering/article-abstract/118/2/248/411721)

First LES of fully-developed turbulent flow in a toroidal pipe. Mean velocity profiles,
secondary flow patterns, rms fluctuations. Useful secondary reference.

### Critical limitation paper

**Lai, Y.G., So, R.M.C., and Zhang, H.S. (1991).**
"Turbulence-Driven Secondary Flows in a Curved Pipe."
*Theoretical and Computational Fluid Dynamics*, 3(3), 163–180.
[Springer](https://link.springer.com/article/10.1007/BF00271800)

**Key finding:** Turbulence itself generates a third vortex pair near the outer wall
(distinct from Dean vortices) caused by anisotropy of cross-stream turbulent normal
stresses. This is fundamentally inaccessible to any isotropic eddy-viscosity model,
including Van Driest mixing-length. A Reynolds Stress Model (RSM) is required to capture
this.

**Implication for our solver:** The Van Driest model will correctly predict friction
factor and mean axial velocity W, but the secondary flow (PHI / OMEGA) will miss the
outer-wall third vortex. This limitation is accepted and should be documented in results.

---

## Turbulence models considered and rejected

| Model | Verdict | Reason |
|---|---|---|
| Van Driest mixing-length | **Chosen** | No extra PDEs; maps directly onto SOR stencil; adequate for friction factor and W |
| Prandtl mixing-length (no damping) | Rejected | Fails in viscous sublayer; log-law overpredicted at low Re |
| k-ε two-equation | Not chosen (yet) | Two additional PDEs; harder to stabilise; needed for non-equilibrium effects |
| Reynolds Stress Model | Not chosen | Seven additional PDEs; required only for turbulence-driven secondary flows |

---

## Van Driest mixing-length model

```
l_m(r, α) = κ · y · [1 − exp(−y⁺ / A⁺)]
ν_T(r, α) = l_m² · |∂W/∂y|
ν_eff(r, α) = ν + ν_T
```

Constants: κ = 0.41, A⁺ = 26.

On the polar grid:
- Wall distance: y = a − r  (a = 1 in dimensionless units, so y = 1 − r_i)
- y⁺ requires u_τ: compute wall shear τ_w = ν · (∂W/∂r)|_{r=a} from one-sided difference at I=NR
- u_τ = sqrt(τ_w)  (dimensionless)

The W and OMEGA SOR stencil coefficients become position-dependent through ν_eff(i,j).
The PHI equation is unchanged (no ν in stream function Laplacian for incompressible flow).

ν_T is frozen between outer iterations and recomputed after each outer convergence, in
the same slot as the Fox corrections C_0/E_0.

---

## Implementation plan (three phases → T-0007, T-0008, T-0009)

### Phase 1 (T-0007): Straight-pipe baseline + new file setup
- Create `Collins_Dennis_1975_turbulent.f90` from the laminar solver
- Add ν_eff computation: Van Driest, computed from W field, updated each correction pass
- Disable curvature (set D_bend=0 or equivalent) to get straight-pipe Poiseuille limit
- Verify log-law velocity profile at Re_τ ≈ 230 vs Hüttl & Friedrich (2001) κ=0 DNS

### Phase 2 (T-0008): Full turbulent curved-pipe solver
- Re-enable curvature; apply ν_eff to both SOR_W and SOR_OMEGA stencil coefficients
- Sweep D from laminar transition (~De=1000) upward
- Compute dimensionless friction factor; compare Ito (1959) correlation

### Phase 3 (T-0009): Comparison and documentation
- Run at De ≈ 1000, 2000, 3500, 5000 (same cases as laminar solver)
- Compare mean axial velocity W profiles vs Hüttl & Friedrich (2001), Noorani et al. (2013)
- Document secondary flow limitation (Lai 1991)
- Plot laminar vs turbulent phi_M and w_M on same axes
