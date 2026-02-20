# CLAUDE.md -- Agent instructions for curved-pipe project

## Build and run

```bash
# Grid (b): NR=20, NA=36 (default)
gfortran -O2 -o cd_central Collins_Dennis_1975_central.f90
./cd_central

# Grid (c): NR=40, NA=72 -- edit line 303 first (swap commented NR/NA line)
gfortran -O2 -o cd_central_c Collins_Dennis_1975_central.f90
./cd_central_c
```

No external dependencies. Single-file Fortran 90 program. Output to stdout + `cd_file_D*.dat` files.

## Project overview

Dean flow solver: laminar flow in a curved pipe. Three coupled fields on a polar (r, alpha) grid:
- **PHI** -- stream function (central differencing, Poisson equation)
- **W** -- axial velocity (upwind SOR + Fox correction C_0)
- **OMEGA** -- vorticity (upwind SOR + Fox correction E_0)

Method: Collins & Dennis (1975) deferred correction. The stable upwind SOR solver is kept as the base; Fox correction terms C_0, E_0 are added as frozen source terms that, when converged, make the solution satisfy the 2nd-order central-difference equations.

Built by upgrading the Schubert (1972) upwind solver published by Basse (2026).

## Source file structure

`Collins_Dennis_1975_central.f90` (~1460 lines):

| Section | Lines | Contents |
|---------|-------|----------|
| MODULE KIND_MOD | 21-24 | `dp = SELECTED_REAL_KIND(15, 307)` |
| MODULE ERROR_MOD | 26-54 | Error handler (codes 55-58) |
| MODULE OUTPUT_MOD | 56-81 | Field array printer |
| MODULE SOR_MOD | 83-293 | SOR_PHI, SOR_W, SOR_OMEGA, SMOOTH (all NaN-guarded) |
| PROGRAM MAIN | 296+ | Declarations, init, case loop, outer iteration |
| CONTAINS | ~1230+ | CHECK_CENTRAL_RESIDUALS, SOLVE_SMALL, ANDERSON_OUTER_UPDATE |

### Grid selection (line 303)

```fortran
INTEGER, PARAMETER :: NR = 2*10, NA = 2*18   ! Grid (b)
! INTEGER, PARAMETER :: NR = 4*10, NA = 4*18 ! Grid (c)
```

To switch grids: swap which line is commented. All arrays are statically sized from NR/NA. Grid-dependent runtime parameters are selected by `IF (NR >= 40)` blocks.

## Key architecture

### Iteration structure (three nested levels)

1. **Case loop** over D = 10, 96, 100, 250, 500, 605.72, 1000, 2000, 3500, 5000
2. **Correction loop** (CORRECTION_LOOP): updates Fox corrections C_0, E_0 after convergence
3. **Outer iteration** (OUTER_ITER): with corrections frozen, iterates W -> Omega -> PHI to convergence
4. Inside each outer iteration: **SOR inner solves** for each field

### Iteration order: W -> Omega -> PHI

This is critical. C&D Section 4, p. 140 specifies this order. PHI SOR runs last, so the wall boundary condition for Omega uses OLD PHI. This one-iteration lag stabilises the coupled iteration at high D. Changing the order (e.g. to PHI first) causes corrections to diverge.

### D-stepping (continuation in D)

For D > 1000, the solver increments D in small steps from the previous converged value:
- Grid (b): Delta_D = 10, STEP_ITERS = 20 outer iterations per step
- Grid (c): Delta_D = 5, STEP_ITERS = 40

At each intermediate D, only STEP_ITERS iterations are performed (no full convergence). Full convergence only at the target D.

### Fox correction computation (C&D eq. 13, 17)

After outer convergence with frozen corrections, new C_0 and E_0 are computed:
```
C_0(i,j) = -(1/2r) * [|DELTA|*(W_E + W_W - 2W_0) + |GAMMA|*(W_N + W_S - 2W_0)]
E_0(i,j) = -(1/2r) * [|DELTA|*(Om_E + Om_W - 2Om_0) + |GAMMA|*(Om_N + Om_S - 2Om_0)]
```
Applied with smoothing: `C_0^{j+1} = omega1 * C_0_new + (1-omega1) * C_0^j`

### Stabilisation techniques

- **2-cycle averaging**: `x_{n+1} = (x_n + T(x_n))/2` kills period-2 oscillation. Threshold: D >= 250 (grid c) or D >= 2000 (grid b). Applied to all three fields including wall BC.
- **Anderson acceleration**: Type-I, depth 4, beta 0.5. Enabled for D >= 3500. History reset when corrections change.
- **Correction 2-cycle averaging**: raw C_0/E_0_NEW values are averaged with previous iteration's raw values before smoothing.
- **Collapse detection**: if w_M drops below 50% of previous pass, restore last good state.
- **NaN detection**: `ieee_is_finite` checks in all SOR routines and SMOOTH.

## Grid-dependent parameters (`IF (NR >= 40)` blocks)

| Parameter | Grid (b) NR=20 | Grid (c) NR=40 |
|-----------|---------------|----------------|
| MAXSOR | 2500 | 50000 |
| STEP_ITERS | 20 | 40 |
| D_STEP | 10 | 5 |
| RHO_W (D=250..2000) | 1.5 | 1.7 |
| EPS_OUT (D>=3500) | loosened | tight (=EPS) |
| OMEGA1 (D=5000) | 0.0 (skip) | 0.01 |
| 2-cycle threshold | D >= 2000 | D >= 250 |

Shared: MAX_CORR=800, MAXOUT=40000, CORR_TOL=5e-4.

## Critical gotchas

1. **gfortran MAX(a, NaN) = a**: NaN is invisible to convergence checks that use MAX for reduction. The code uses SUM-based NaN propagation and ieee_is_finite guards.
2. **Uncorrected solution handoff**: D-stepping resets corrections to zero. The initial guess for the next D case must be the uncorrected solution, not the corrected one. PHI_UNCORR/W_UNCORR/OMEGA_UNCORR are saved for this.
3. **Convergence check on unrelaxed update**: The `SMOOTH` subroutine checks `ABS(old - relaxed) > XIC*EPS` (not `EPS`), because the relaxed update is `XI*old + XIC*raw`, so `old - relaxed = XIC*(old - raw)`.
4. **Anderson coefficient safeguard**: if max|alpha| > 10, the Anderson history is reset to prevent wild extrapolation.
5. **Full stencil at I=NR**: the code uses the full central-difference stencil at the wall-adjacent point (no parabolic 0.25 approximation). This is more accurate but needs the 2-cycle averaging for stability.

## Verification

Expected results for grid (c) matching C&D (1975):

| D | phi_M | w_M |
|------|-------|--------|
| 96 | 0.99 | 23.33 |
| 500 | 6.12 | 83.66 |
| 1000 | 9.20 | 141.30 |
| 3500 | 17.11 | 351.24 |
| 5000 | 19.93 | 449.37 |

Grid (c) runtime: ~38 seconds. Grid (b): ~5 seconds.

To verify, grep for `PHI_M` in the output:
```bash
./cd_central 2>&1 | grep PHI_M
```

## Other files

| File | Purpose |
|------|---------|
| `Schubert_1972_complete_modern_Fortran.f90` | Original upwind-only solver (Basse 2026 Appendix C) |
| `Collins_Dennis_1975_central_C0only.f90` | C_0 correction only variant (E_0=0) |
| `verify_fox.py` | Algebraic verification that upwind + C_0 = central difference |
| `problem_description_for_chatgpt.md` | Full derivation of C_0, E_0 formulae with normalisations |
| `background.md` | Basse (2026) paper summary and physics background |
| `wotan/dev-log/T-0001..T-0005.md` | Detailed development logs for each task |

## Development history

Starting from Basse's modernised Schubert (1972) upwind solver:

1. **Step 0**: Added Fox corrections C_0, E_0 with two-level iteration. Fixed iteration order to W -> Omega -> PHI (C&D Section 4). Matched C&D for D <= 1000.
2. **T-0001**: Fixed convergence checking (unrelaxed update), added wall BC diagnostic, stabilised high-D XI parameters.
3. **T-0002**: Made Omega SOR boundary propagation consistent (defensive).
4. **T-0003**: Carry Fox corrections between D cases; save uncorrected solution for D-stepping handoff.
5. **T-0004**: 2-cycle averaging stabiliser. Matched C&D phi_M at all D values. Grid (c) file created.
6. **T-0005**: Anderson acceleration + NaN detection. Closed w_M gap at D=5000 (449.37 vs C&D 449.3).
7. **Grid merge**: Combined grid (b) and grid (c) into single parameterised source file.
