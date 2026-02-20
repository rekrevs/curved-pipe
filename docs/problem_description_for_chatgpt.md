# Problem: Fox's Deferred Correction Produces Wrong Results for Dean Flow Solver

## 1. Context

We are implementing the numerical method from **Collins & Dennis (1975)** "The steady motion of a viscous fluid in a curved tube", Q. Jl Mech. appl. Math., 28(2), 133-156.

The problem is steady laminar flow in a curved pipe (Dean flow). The governing PDEs in dimensionless polar coordinates (r, alpha) on the pipe cross-section are (C&D equations 3-5):

**Stream function** (phi): nabla^2(phi) = -Omega   ... (3)

**Axial velocity** (w):
```
d2w/dr2 + (1/r)dw/dr + (1/r2)d2w/dalpha2 + (1/r)(dphi/dr * dw/dalpha - dphi/dalpha * dw/dr) = -D   ... (4)
```

**Vorticity** (Omega):
```
d2Omega/dr2 + (1/r)dOmega/dr + (1/r2)d2Omega/dalpha2
  + (1/r)(dphi/dr * dOmega/dalpha - dphi/dalpha * dOmega/dr)
  = w * (sin(alpha) * dw/dr + cos(alpha)/r * dw/dalpha)   ... (5)
```

where D = 4R*sqrt(2a/L) is the Dean number.

**Note the sign in eq (4)**: the advection term is `(dphi/dr * dw/dalpha - dphi/dalpha * dw/dr)`, i.e., the Laplacian contribution (1/r)dw/dr MINUS the stream function advection `(dphi/dalpha * dw/dr)/r` gives a combined first-order r-derivative coefficient of `(1 - dphi/dalpha)/r`.

Domain: semi-circular cross-section, 0 <= r <= 1, 0 <= alpha <= pi (symmetry about alpha=0).
Grid: NR=20 radial points, NA=36 angular points (h=0.05, k=pi/36). This is C&D's "grid (b)".

## 2. The Two Numerical Schemes

### 2.1 Upwind Scheme (Greenspan/Schubert)

Our baseline solver uses the **forward-and-backward difference scheme** of Greenspan (1973), implemented by Schubert (1972). For the w equation, the advection terms are upwinded based on local flow direction.

Define at each grid point (i,j):
```
GAMMA = 0.5 * (phi_{i+1,j} - phi_{i-1,j})   ≈ h * dphi/dr
DELTA = k - 0.5 * (phi_{i,j+1} - phi_{i,j-1})  ≈ k * (1 - dphi/dalpha)
```

The **upwind stencil** (multiply PDE by h*k) has coefficients:
```
a_E = k/h + MAX(DELTA,0)/r_0           [w_{i+1,j}]
a_N = h/(k*r_0^2) + MAX(GAMMA,0)/r_0   [w_{i,j+1}]
a_W = k/h + MAX(-DELTA,0)/r_0          [w_{i-1,j}]
a_S = h/(k*r_0^2) + MAX(-GAMMA,0)/r_0  [w_{i,j-1}]
a_0 = a_E + a_N + a_W + a_S            [center coefficient]
source = D * h * k
```

Equation: `a_E*w_1 + a_N*w_2 + a_W*w_3 + a_S*w_4 - a_0*w_0 + D*h*k = 0`

The same stencil (same DELTA, GAMMA) is reused for the Omega equation (same LHS structure), with the w*dw source term on the RHS.

### 2.2 Central Difference Scheme (Collins & Dennis target)

For **central differencing**, the first-order derivatives use symmetric stencils:
```
b_E = k/h + DELTA/(2*r_0)
b_N = h/(k*r_0^2) + GAMMA/(2*r_0)
b_W = k/h - DELTA/(2*r_0)
b_S = h/(k*r_0^2) - GAMMA/(2*r_0)
b_0 = 2*(k/h + h/(k*r_0^2))    [note: no |DELTA|, |GAMMA| terms]
source = D * h * k   [same]
```

Central differencing is 2nd-order accurate but loses diagonal dominance (b_E or b_W can be negative), making direct SOR unreliable.

## 3. Fox's Deferred Correction Method (C&D Approach)

C&D's key insight: keep the **stable upwind SOR** as the iterative solver, but add a **correction term** C_0 as a frozen source that, when converged, makes the solution satisfy the central-difference equation.

### 3.1 Derivation of C_0

The difference between central and upwind equations:
```
Central eq - Upwind eq = C_0
```

We verified algebraically (for DELTA > 0, GAMMA > 0):
```
w_1 coeff: DELTA/(2r) - DELTA/r = -DELTA/(2r)
w_2 coeff: GAMMA/(2r) - GAMMA/r = -GAMMA/(2r)
w_3 coeff: -DELTA/(2r) - 0 = -DELTA/(2r)
w_4 coeff: -GAMMA/(2r) - 0 = -GAMMA/(2r)
w_0 coeff: -2(k/h + h/(kr^2)) + (2(k/h + h/(kr^2)) + (|DELTA|+|GAMMA|)/r) = (|DELTA|+|GAMMA|)/r
```

So (for general signs):
```
C_0 = -(1/(2r)) * [|DELTA| * (w_1 + w_3 - 2*w_0) + |GAMMA| * (w_2 + w_4 - 2*w_0)]
```

This matches C&D eq (13) after converting normalizations:
- C&D normalize by h^2: `C_0_CD = -h|lambda_0|(w_1+w_3-2w_0) - (h^2|mu_0|/k)(w_2+w_4-2w_0)`
- Our Schubert code normalizes by h*k: `C_0_Schubert = (k/h) * C_0_CD`
- With `lambda_0 = DELTA/(2*k*r_0)` and `mu_0 = GAMMA/(2*h*r_0)`:
  - `C_0_Schubert = -(1/(2r_0)) * [|DELTA|*(w_1+w_3-2w_0) + |GAMMA|*(w_2+w_4-2w_0)]` ✓

### 3.2 E_0 correction for Omega

The Omega equation has the same LHS structure (Laplacian + advection with same phi), so:
```
E_0 = -(1/(2r)) * [|DELTA| * (Omega_1 + Omega_3 - 2*Omega_0) + |GAMMA| * (Omega_2 + Omega_4 - 2*Omega_0)]
```

The RHS of the Omega equation (w*dw source) already uses central differences and needs no correction.

### 3.3 Two-Level Iteration (C&D Section 4)

C&D's algorithm:
1. **Inner iteration**: With C_0 and E_0 held fixed, iterate phi -> w -> Omega to convergence using SOR
2. **Correction update**: From converged fields, compute new C_0 and E_0. Apply smoothing:
   ```
   C_0^{j+1} = omega_1 * C_0_new + (1 - omega_1) * C_0^j
   ```
   where omega_1 = 1.0 for D <= 1000, 0.1 for D=2000, 0.05 for D=3500, 0.01 for D=5000
3. **Repeat** until corrections converge

## 4. Our Implementation

### 4.1 How C_0 enters the SOR

The W equation SOR uses normalized coefficients `E(I,J,1-5)` where `E(I,J,5) = source/denominator`:
```fortran
! Upwind coefficients (same as original Schubert)
E(I,J,6) = EE(I) + RINV(I) * (ABS(GAMMA) + ABS(DELTA))   ! upwind denominator
E(I,J,1) = (DADR + RINV(I) * MAX(DELTA,0)) / E(I,J,6)    ! east coeff
E(I,J,2) = (EF(I) + RINV(I) * MAX(GAMMA,0)) / E(I,J,6)   ! north coeff
E(I,J,3) = (DADR - RINV(I) * MIN(DELTA,0)) / E(I,J,6)    ! west coeff
E(I,J,4) = (EF(I) - RINV(I) * MIN(GAMMA,0)) / E(I,J,6)   ! south coeff
! Source with FROZEN Fox correction
E(I,J,5) = (D*h*k + C0_CORR(I,J)) / E(I,J,6)             ! corrected source
```

The SOR then solves: `w_0 = E1*w_1 + E2*w_2 + E3*w_3 + E4*w_4 + E5`

### 4.2 How E_0 enters the Omega SOR

The Omega source is computed from the converged W field, and E_0 is added before normalization:
```fortran
OMEGA_RHS = -W(I,J,3) * (SA(J)*(W(I+1,J,3)-W(I-1,J,3)) + CA(I,J)*(W(I,J+1,3)-W(I,J-1,3)))
E(I,J,6) = (OMEGA_RHS + E0_CORR(I,J)) / E(I,J,6)   ! E(I,J,6) on RHS is W's upwind denominator
```

The Omega SOR reuses E(I,J,1-4) from the W stencil (valid because Omega has the same advection structure).

### 4.3 Correction computation (after inner convergence)

```fortran
DO I = 2, NR
  DO J = 2, NA
    GAMMA = .5 * (PHI(I+1,J,3) - PHI(I-1,J,3))
    DELTA = DA - .5 * (PHI(I,J+1,3) - PHI(I,J-1,3))

    C0_CORR_NEW(I,J) = -0.5 * RINV(I) * ( &
      ABS(DELTA) * (W(I+1,J,3) + W(I-1,J,3) - 2*W(I,J,3)) + &
      ABS(GAMMA) * (W(I,J+1,3) + W(I,J-1,3) - 2*W(I,J,3)))

    E0_CORR_NEW(I,J) = -0.5 * RINV(I) * ( &
      ABS(DELTA) * (OMEGA(I+1,J,3) + OMEGA(I-1,J,3) - 2*OMEGA(I,J,3)) + &
      ABS(GAMMA) * (OMEGA(I,J+1,3) + OMEGA(I,J-1,3) - 2*OMEGA(I,J,3)))
  END DO
END DO

! Apply smoothing (C&D eq. 21)
C0_CORR(I,J) = omega1 * C0_CORR_NEW(I,J) + (1-omega1) * C0_CORR(I,J)
E0_CORR(I,J) = omega1 * E0_CORR_NEW(I,J) + (1-omega1) * E0_CORR(I,J)
```

## 5. Results: The Problem

### 5.1 Comparison table at D = 500, grid (b)

| Metric | Upwind (our baseline) | Fox corrected (ours, C0+E0) | Fox C0 only (E0=0) | C&D corrected |
|--------|----------------------|----------------------------|--------------------|----|
| phi_M  | 7.142                | **7.410** (↑ WRONG!)        | 7.273 (↑ wrong)   | **6.166** |
| w_M    | 69.29                | 72.29 (↑ correct dir)       | 73.43 (↑ better)  | **83.50** |
| QR     | 0.630                | 0.658                       | -                  | **0.815** |

### 5.2 Comparison at other D values

| D    | phi_M upwind | phi_M corrected (ours) | phi_M C&D | w_M upwind | w_M corrected (ours) | w_M C&D |
|------|-------------|----------------------|-----------|-----------|---------------------|---------|
| 96   | ~0.02       | 0.0228               | 0.995     | ~2.4      | 2.50                | 23.34   |
| 500  | 7.142       | 7.410                | 6.166     | 69.29     | 72.29               | 83.50   |
| 1000 | 10.396      | 10.752               | 9.308     | 114.48    | 123.07              | 140.6   |

### 5.3 Key observations

1. **phi_M consistently INCREASES** with corrections, but C&D's corrected values are LOWER than our upwind baseline. The corrections push phi_M in the WRONG direction.

2. **w_M increases** (correct direction), but not nearly enough. At D=500: we get 72.29, target is 83.50 (only ~20% of the needed increase achieved).

3. **Disabling E_0** (C0 only, E0=0) slightly improves w_M (73.43 vs 72.29) and slightly reduces the phi_M overshoot (7.273 vs 7.410). So E_0 makes BOTH metrics worse.

4. **Correction iterations converge** well for D <= 1000 (4-9 iterations with omega1=1.0). The max correction residuals decrease monotonically.

5. **For D >= 2000**, corrections converge very slowly even with small omega1.

## 6. What We Have Verified

1. **Algebraic correctness of C_0**: The formula `C_0 = -(1/(2r))[|DELTA|*(w_E+w_W-2w_0) + |GAMMA|*(w_N+w_S-2w_0)]` is the EXACT difference between the central-diff and upwind equations in Schubert's normalization (h*k). Verified by expanding all stencil coefficients.

2. **Consistency with C&D eq (13)**: Our formula matches C&D's `C_0 = -h|lambda_0|(w_1+w_3-2w_0) - (h^2|mu_0|/k)(w_2+w_4-2w_0)` after converting between h^2 and h*k normalizations.

3. **Upwind scheme consistency**: Both Schubert and C&D use the same "forward differencing" convention (enhance east coefficient when DELTA > 0). The stencil coefficients match after normalization conversion.

4. **Stencil direction labeling**: W(I+1,J) = east = w_1, W(I-1,J) = west = w_3, W(I,J+1) = north = w_2, W(I,J-1) = south = w_4. Verified against both Southwell notation and Fortran array indexing.

5. **E_0 has the same form**: Omega equation has identical LHS structure (same advection velocities), so the correction has the same form with Omega replacing W.

6. **Two-level iteration structure**: Matches C&D Section 4 description. Corrections frozen during inner SOR convergence, updated after convergence.

## 7. Possible Issues We Cannot Resolve

1. **Maybe the Schubert upwind scheme is subtly different from Greenspan's**. Our upwind phi_M=7.142 at D=500, while C&D cite Greenspan's value as phi_M=6.70 (Table 3). That's a 6.5% difference. Could indicate a different discretization or boundary treatment.

2. **Maybe C&D use a different equation than what Schubert implements**. Although both reference the same PDEs (eqs 3-5), the actual discretization of boundary conditions (at r=0, r=1, alpha=0, alpha=pi) could differ.

3. **Maybe the deferred correction interacts badly with the outer (phi-w-Omega coupling) iteration**. C&D solve w first, then phi, then Omega. Our code solves phi first, then w, then Omega. Although the converged solution should be the same, the iteration path differs.

4. **Maybe the correction formula needs additional terms we're missing**. For example, C&D mention (page 142) that the correction procedure is that of eq (16), involving the Cartesian representation at r=0. Perhaps there are corrections needed at boundaries that we're not implementing.

5. **Maybe the sign convention in eq (4) differs between C&D and Schubert**. Although we've verified the algebra, if there's a sign error in the original Schubert code that our code inherits, the correction could be applied incorrectly.

## 8. The Core Question

Given that:
- The Fox correction formula C_0 is algebraically verified to be the exact difference between central and upwind discrete equations
- The two-level iteration converges
- But the results go in the WRONG direction for phi_M

**What could cause the deferred correction to converge to a solution that is WORSE than the upwind solution, rather than converging to the central-difference solution?**

## 9. Full Code

The complete Fortran 90 code is in `Collins_Dennis_1975_central.f90` (917 lines). Key sections:

- Lines 586-632: W coefficient setup with upwind stencil + C_0 source
- Lines 669-677: Omega source computation with E_0
- Lines 749-833: Correction computation and two-level iteration logic
- Lines 536-735: Full outer iteration loop with D-stepping

The baseline upwind solver (without corrections) is in `Schubert_1972_complete_modern_Fortran.f90` (874 lines).
