# Theoretical Basis for the Turbulent Dean Flow Solver

*Document version: 2026-02-27. Companion to `Collins_Dennis_1975_turbulent.f90`.*

---

## 1. Problem formulation

We consider fully-developed turbulent flow in a toroidal pipe of circular
cross-section, with inner radius `a` and bend (centreline) radius `R`. The
geometry is the same as Collins & Dennis (1975) for the laminar case.

The relevant dimensionless parameter is the **Dean number**

```
D = Re · √(2δ),     δ = a/R  (curvature ratio)
```

where `Re = U_bulk · a / ν` is the Reynolds number based on bulk velocity and
molecular kinematic viscosity. Collins & Dennis (1975) use this definition;
it differs from some literature by the factor √2.

The **critical Dean number for laminar–turbulent transition** in curved pipes is
approximately (Ito 1959)

```
Re_c ≈ 2.1 × 10⁴ · δ^0.45
```

For the Collins & Dennis geometry (δ = 0.05, R/a = 20) this gives Re_c ≈ 5040
and D_c ≈ 1130. The present turbulent solver therefore targets D ≥ 1000.

---

## 2. Reynolds-averaged governing equations

Starting from the incompressible Navier–Stokes equations in toroidal coordinates
`(r, α, s)` — r radial (cross-section), α circumferential, s axial along the
bend — Reynolds-averaging introduces the eddy-stress tensor. Under the
**eddy-viscosity (Boussinesq) hypothesis**, the Reynolds stresses are modelled as

```
−⟨u_i′ u_j′⟩ = ν_T (∂⟨u_i⟩/∂x_j + ∂⟨u_j⟩/∂x_i)
```

where `ν_T` is the turbulent kinematic viscosity (eddy viscosity). This replaces
the molecular viscosity `ν` everywhere with the **effective viscosity**

```
ν_eff(r, α) = ν + ν_T(r, α)
```

The three RANS equations for fully-developed Dean flow then take the same
form as the laminar equations of Collins & Dennis (1975), but with `ν` replaced
by `ν_eff` in all diffusion terms:

### Axial velocity W

```
∇·(ν_eff ∇W) − (1/r) [ Ψ_α W_r − Ψ_r W_α ] = −(1/ρ) ∂⟨p⟩/∂s
```

### Vorticity Ω

```
∇·(ν_eff ∇Ω) − (1/r) [ Ψ_α Ω_r − Ψ_r Ω_α ] = D · sin(α) · W · W_r
                                                 + D · cos(α)/r · W · W_α
```

(secondary-flow source terms, same as laminar)

### Stream function Ψ

```
∇²Ψ = −Ω
```

The stream function equation is **purely kinematic** (derived from
incompressibility) and contains no viscosity. It is therefore **unchanged** in
the turbulent solver. This is a crucial correctness constraint: injecting `ν_eff`
into the Ψ equation would be physically wrong.

The discretisation follows Approach 5 (face-averaged viscosity, §5 below).

---

## 3. Turbulence closure: algebraic mixing-length model

### 3.1 Prandtl mixing-length hypothesis

Prandtl (1925) proposed that the turbulent viscosity is related to the local
velocity gradient and a mixing length `ℓ_m`:

```
ν_T = ℓ_m² · |dU/dy|
```

where `y` is the distance from the nearest wall. For internal pipe flow the
"velocity" is the axial component W and `y = a − r`.

### 3.2 Van Driest wall damping

The plain mixing-length model predicts non-zero `ν_T` arbitrarily close to the
wall, conflicting with the viscous sublayer (`u⁺ = y⁺` for `y⁺ < 5`). Van
Driest (1956) introduced exponential damping to enforce the correct near-wall
behaviour:

```
ℓ_m = κ · y · [1 − exp(−y⁺ / A⁺)]
```

with

```
κ = 0.41   (von Kármán constant)
A⁺ = 26    (Van Driest constant, smooth wall)
y⁺ = y · u_τ / ν   (inner coordinate)
u_τ = √(τ_w / ρ) = √(ν · |∂W/∂r|_{r=a})   (friction velocity)
```

The combined turbulent viscosity is then

```
ν_T(r, α) = ℓ_m² · |∂W/∂r(r, α)|
```

Note that `ν_T → 0` at the wall (`y → 0`), recovering the viscous sublayer.

### 3.3 Nikuradse outer-layer cap

For large `y` (pipe centre), the plain Van Driest mixing length grows without
bound, over-predicting `ν_T` in the outer region and under-predicting the
centreline velocity. Nikuradse (1932, 1933) showed experimentally that in pipe
flow the mixing length saturates at approximately

```
ℓ_m ≤ L_max = 0.14 · a
```

This cap is applied in the solver:
```fortran
L_MIX = MIN(KAPPA_VD * Y * (1.0 - EXP(-Y_PLUS / A_PLUS)),  0.14_dp)
```

### 3.4 Self-consistent friction velocity

The friction velocity `u_τ` is **not prescribed**; it is computed
self-consistently from the converged W field at each outer iteration:

```
u_τ = √(ν_mol · |∂W/∂r|_{r=a,avg})
```

where `∂W/∂r|_{r=a}` is the circumferentially averaged wall velocity gradient.
This ensures `ν_T` reflects the actual state of the solution and `Re_τ = u_τ · a / ν`
emerges as a result rather than an input.

---

## 4. Iteration and update schedule

The turbulent viscosity field is **frozen** during the SOR inner iterations and
the outer iteration convergence loop. It is updated once per correction-loop
pass, at the same point as the Fox deferred-correction terms C₀ and E₀:

```
Correction pass j:
  1. Outer iteration (W → Ω → Ψ) to convergence with frozen ν_eff
  2. Compute new Fox corrections C₀, E₀ from converged W, Ω
  3. Compute new ν_eff from converged W  ← Van Driest update
  4. Apply under-relaxation: ν_eff ← ω · ν_eff_new + (1−ω) · ν_eff_old
  5. Check correction convergence; repeat if not converged
```

This "frozen-viscosity" philosophy mirrors the deferred-correction approach of
Collins & Dennis: the SOR base solver always sees a fixed, diagonally-dominant
stencil; all correction terms (Fox and turbulent) enter as frozen sources or
coefficient modifications that are lagged by one correction pass.

Under-relaxation of the ν_eff update (ω < 1) is used during D-stepping to
prevent the viscosity field from changing too rapidly when W changes
significantly between D increments.

---

## 5. Discrete formulation: face-averaged viscosity

The diffusion operator `∇·(ν_eff ∇W)` is discretised using **face-averaged
viscosity** (finite-volume style). At each interior cell (i, j) the diffusive
fluxes through the four faces use the arithmetic mean of adjacent cell values:

```
ν_E = ½(ν_eff(i+1,j) + ν_eff(i,j))     (east face, radial direction)
ν_W = ½(ν_eff(i−1,j) + ν_eff(i,j))     (west face)
ν_N = ½(ν_eff(i,j+1) + ν_eff(i,j))     (north face, angular direction)
ν_S = ½(ν_eff(i,j−1) + ν_eff(i,j))     (south face)
```

The radial part of the cylindrical Laplacian `(1/r) ∂/∂r(r ν_eff ∂W/∂r)` is
handled by including the 1/r metric in the stencil denominators:

```
DIFF_E = (DA/DR) · ν_E + ½ · DA · (1/r_i) · ν_eff(i,j)
DIFF_W = (DA/DR) · ν_W − ½ · DA · (1/r_i) · ν_eff(i,j)
DIFF_N = (DR/DA) · (1/r_i²) · ν_N
DIFF_S = (DR/DA) · (1/r_i²) · ν_S
```

This discretisation captures both the `ν_eff · ∇²W` term and the
`∇ν_eff · ∇W` cross-term automatically and to second order, without requiring
explicit computation of `∇ν_eff`. Setting `ν_eff = 1` everywhere exactly
recovers the laminar solver stencil.

The upwind convection terms (stream-function coupling) are unchanged.

---

## 6. Friction factor and validation target

### 6.1 Darcy–Weisbach friction factor

The friction factor in the solver's dimensionless units (a=1, ν=1) is

```
f = 8 · τ_w,avg / W_m²
```

where τ_w,avg is the circumferentially averaged wall shear stress

```
τ_w,avg = (1/NA) Σ_j |∂W/∂r|_{r=a,j}  ≈  (1/NA) Σ_j  W(NR,j) / DR
```

and W_m is the mean axial velocity, obtained from the solver's flux ratio:

```
W_m = QR · D / 4
```

(Here QR = Q_actual / Q_Poiseuille and Q_Poiseuille = πD/8 in solver units,
giving Q_actual = QR · πD/8 and W_m = Q_actual/(π a²) = QR·D/8 · (1/π) · π = QR·D/8.
Wait — more carefully: QR = (8/πD) ∫₀ᵃ ∫₀^π W r dr dα. So W_m = QR · D / 8 if
the integral is over a half-annulus [0,π]. Since the solver uses α ∈ [0,π] with
the symmetry plane, and area = πa²/2, W_m = QR · D / 4.)

The Reynolds number is computed from the Dean number and the curvature ratio:

```
Re = D / √δ   (since D = Re · √(2δ) / √2, so Re ≈ D / √δ for the C&D definition)
```

For δ = 0.05 (R/a = 20): Re = D / √0.05 = D · 4.4721.

### 6.2 Ito (1959) target

Ito (1959) measured friction factors for turbulent flow in smooth curved pipes
over a wide range of Re and δ and fitted the correlation:

```
f_c = 0.304 · Re^{−0.25} · (R/a)^{−0.05}     [Darcy, smooth wall, turbulent]
```

The straight-pipe Blasius reference is `f₀ = 0.316 · Re^{−0.25}`, giving

```
f_c / f₀ ≈ 0.304/0.316 · 20^{−0.05} ≈ 0.82   (for R/a = 20, weakly Re-dependent)
```

**Physically**, turbulence in a curved pipe reduces the friction factor relative
to a straight pipe at the same Re. This is the opposite of the laminar regime,
where Dean vortices increase resistance. The centrifugal force stabilises the
turbulent boundary layer near the outer wall, reducing the effective mixing.

The automated acceptance gate is 20% relative error against the Ito correlation
for D ≥ 1000 (`verify_ito.py`). The aspirational target is 15%.

---

## 7. Known limitations of the Van Driest model

### 7.1 Isotropic eddy viscosity

The Boussinesq hypothesis assumes the Reynolds-stress tensor is proportional to
the mean strain-rate tensor via a scalar `ν_T`. This is exact only for isotropic
turbulence, which is not realised in curved-pipe flow where centrifugal and
Coriolis effects create strong anisotropy.

### 7.2 Turbulence-driven secondary flows (Lai et al. 1991)

In curved pipes, anisotropy of the cross-stream turbulent normal stresses
(`⟨v′v′⟩ ≠ ⟨w′w′⟩`) generates a third pair of counter-rotating vortices near
the outer wall, in addition to the two Dean vortices driven by the centrifugal
instability. This "turbulence-driven secondary flow" is **inaccessible to any
isotropic eddy-viscosity model**, including Van Driest mixing-length. A
Reynolds Stress Model (RSM) or differential second-moment closure is required
to capture it (Lai, So & Zhang 1991).

**Implication**: The present solver can accurately predict the mean axial
velocity W and the Darcy friction factor. The secondary flow pattern (Ψ, Ω) in
the turbulent regime will reproduce the two laminar-like Dean vortices but will
miss the outer-wall third vortex pair.

### 7.3 Absence of a wake component

The Van Driest model with Nikuradse cap gives a centreline velocity
`u⁺_CL ≈ 18–19` at moderate Re_τ, whereas DNS data (Hüttl & Friedrich 2001)
and the log-law wake function give `u⁺_CL ≈ 22–23`. The missing contribution is
the **Coles wake term** `(Π/κ) · w(y/δ)`, where `Π ≈ 0.2–0.55` is the wake
parameter. Mixing-length models without an explicit wake function systematically
under-predict the centreline velocity by 15–20%.

### 7.4 No relaminarisation modelling

At high curvature and moderate Re, turbulence is partially suppressed near the
inner wall (relaminarisation). DNS by Hüttl & Friedrich (2001) at κ = 0.1,
Re_bulk = 5300 shows strong suppression there. The Van Driest model responds to
this through the `|∂W/∂r|` term in `ν_T`: where the velocity gradient is small,
`ν_T` is small. This provides a qualitatively correct but quantitatively
imprecise representation of relaminarisation.

---

## 8. References

**Collins, M.W. and Dennis, S.C.R. (1975).**
"The steady motion of a viscous fluid in a curved tube."
*Quarterly Journal of Mechanics and Applied Mathematics*, 28(2), 133–156.
DOI: 10.1093/qjmam/28.2.133.
— *Primary reference for governing equations, Dean flow formulation, deferred correction method.*

**Prandtl, L. (1925).**
"Bericht über Untersuchungen zur ausgebildeten Turbulenz."
*Zeitschrift für angewandte Mathematik und Mechanik*, 5(2), 136–139.
— *Original mixing-length hypothesis.*

**Van Driest, E.R. (1956).**
"On turbulent flow near a wall."
*Journal of the Aeronautical Sciences*, 23(11), 1007–1011.
DOI: 10.2514/8.3713.
— *Wall-damping function for mixing-length model; A⁺ = 26, κ = 0.41.*

**Nikuradse, J. (1932).**
"Gesetzmässigkeiten der turbulenten Strömung in glatten Rohren."
*Forschungsheft*, 356. VDI-Verlag, Berlin.
**Nikuradse, J. (1933).**
"Strömungsgesetze in rauhen Rohren."
*Forschungsheft*, 361. VDI-Verlag, Berlin.
— *Experimental basis for mixing-length saturation in pipe flow; outer cap ℓ_m ≤ 0.14a.*

**Ito, H. (1959).**
"Friction factors for turbulent flow in curved pipes."
*ASME Journal of Basic Engineering*, 81(2), 123–132.
DOI: 10.1115/1.4008390.
— *Primary validation target: f_c = 0.304·Re^{−0.25}·(R/a)^{−0.05}; transition criterion Re_c.*

**Patankar, S.V., Pratap, V.S. and Spalding, D.B. (1975).**
"Prediction of turbulent flow in curved pipes."
*Journal of Fluid Mechanics*, 67(3), 583–595.
DOI: 10.1017/S0022112075000481.
— *First RANS computation of turbulent Dean flow; curved-pipe governing equations in stream-function/vorticity form.*

**Lai, Y.G., So, R.M.C. and Zhang, H.S. (1991).**
"Turbulence-driven secondary flows in a curved pipe."
*Theoretical and Computational Fluid Dynamics*, 3(3), 163–180.
DOI: 10.1007/BF00271800.
— *Shows isotropic eddy-viscosity models miss outer-wall third vortex; RSM required.*

**Hüttl, T.J. and Friedrich, R. (2001).**
"Direct numerical simulation of turbulent flows in curved and helically coiled pipes."
*Computers & Fluids*, 30(5), 591–605.
DOI: 10.1016/S0045-7930(01)00008-1.
— *DNS reference data at Re_τ = 230, κ = 0.01 and 0.1; validation target for velocity profiles.*

**Noorani, A., El Khoury, G.K. and Schlatter, P. (2013).**
"Evolution of turbulence characteristics from straight to curved pipes."
*International Journal of Heat and Fluid Flow*, 41, 16–26.
DOI: 10.1016/j.ijheatfluidflow.2013.03.005.
— *DNS at Re_bulk = 5300 and 11700, κ = 0, 0.01, 0.1; full Reynolds-stress budgets.*

**Boersma, B.J. and Nieuwstadt, F.T.M. (1996).**
"Large-eddy simulation of turbulent flow in a curved pipe."
*ASME Journal of Fluids Engineering*, 118(2), 248–254.
DOI: 10.1115/1.2817370.
— *First LES of fully-developed turbulent toroidal pipe flow.*
