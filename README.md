# Dean Flow Solver: Collins & Dennis (1975) Deferred Correction Method

Numerical solver for laminar flow in a curved pipe (Dean flow), implementing Fox's
deferred correction method as described by Collins & Dennis (1975). Built by
progressively upgrading the Schubert (1972) upwind solver to achieve 2nd-order
central-difference accuracy across all Dean numbers D = 10 to 5000.

## Physics

The Dean equations describe the steady, fully developed laminar flow of a viscous
fluid through a slightly curved pipe. The curvature drives secondary flow
(counter-rotating Dean vortices) in the pipe cross-section, while the pressure
gradient maintains axial flow. Three coupled PDEs are solved on a polar
cross-section grid (r, alpha):

- **phi(r, alpha)** -- stream function for secondary flow
- **w(r, alpha)** -- streamwise (axial) velocity
- **Omega(r, alpha)** = -nabla^2(phi) -- streamwise vorticity

The Dean number D = 4 Re sqrt(2a/L) is the single governing parameter,
where Re is the Reynolds number, a the pipe radius, and L the radius of curvature.
As D increases, the velocity peak shifts outward, Dean vortices intensify, and the
flux ratio (relative to a straight pipe) drops.

## Origin and motivation

This code builds on the modernised Fortran 90 solver published by Basse (2026) as
Appendix C of "Application of artificial intelligence to revive numerical studies of
fluid motion in a curved pipe" (Discover Mechanical Engineering 5:21). Basse used AI
tools to digitise and modernise a 1972 FORTRAN 66 program by Schubert (from Greenspan
& Schubert, University of Wisconsin Technical Report 155, 1972), which solves the Dean
equations using **upwind differencing** and SOR. The modernised code (`Schubert_1972_complete_modern_Fortran.f90`) runs correctly but uses first-order upwind differencing for w and Omega,
producing results that deviate substantially from the more accurate second-order
results of Collins & Dennis (1975).

Collins & Dennis (1975) achieved second-order accuracy by keeping the stable upwind
SOR solver but adding **Fox's deferred correction terms** C_0 and E_0 as frozen source
terms. When the two-level iteration converges, the solution satisfies the
central-difference equations while retaining the guaranteed diagonal dominance and
convergence of the upwind solver.

Our goal was to implement the Collins & Dennis method and reproduce their published
results across all Dean numbers.

## Development history

The upgrade was carried out in seven steps, tracked as wotan tasks T-0001 through
T-0005 plus two additional structural changes. Each step is documented in detail
in `wotan/dev-log/`.

### Step 0: Baseline Fox correction implementation

Starting from Basse's modernised Schubert code, we added Fox correction terms C_0
(for the W equation, C&D eq. 13) and E_0 (for the Omega equation, C&D eq. 17) with
the two-level iteration structure described in C&D Section 4. We also added correction
smoothing (C&D eq. 21), D-stepping for high Dean numbers, and additional D cases
(D = 96, 605.72) matching C&D's paper.

The critical insight at this stage was identifying the correct **iteration order**.
The original Schubert code solves phi first, then w, then Omega. Collins & Dennis
(Section 4, p. 140) solve **W -> Omega -> phi**. This seemingly minor change gives a
one-iteration lag in the wall boundary condition that stabilises the coupled iteration
at high D. Getting this wrong caused the corrections to push phi_M in the wrong
direction (increasing instead of decreasing), which was diagnosed through extensive
algebraic verification of the correction formulae documented in
`problem_description_for_chatgpt.md` and `verify_fox.py`.

After fixing the iteration order, results matched C&D for D <= 1000 on grid (b)
(NR=20, NA=36).

### T-0001: Fix convergence checking and stabilise high-D parameters

**Problem:** The outer iteration at D >= 2000 appeared to converge but produced
near-trivial solutions. Root cause: the convergence test measured the *relaxed*
update `(1-XI) * (raw - old)`, so large XI values caused false convergence.

**Fix:** Changed all convergence checks (in SMOOTH, W-origin, Omega-wall) to judge
the *unrelaxed* update. Added wall BC residual diagnostic. Applied stabilised XI
parameters for D >= 2000.

**Result:** D <= 1000 regression passed (identical). D >= 2000 no longer converged
to trivial solutions but still oscillated without converging.

### T-0002: Make Omega SOR boundary propagation consistent

**Problem:** Omega boundary values in SOR slice 2 could be stale if not explicitly
propagated before each SOR sweep.

**Fix:** Added explicit propagation of all four Omega boundary slices (wall, r=0,
alpha=0, alpha=pi) to the SOR "old" array before each Omega SOR call.

**Result:** Defensive fix -- no numerical change, but eliminates a class of
potential boundary inconsistency bugs.

### T-0003: Carry Fox corrections between D cases

**Problem:** Each D case started with zero corrections, discarding work from the
previous case. For D <= 1000 (where corrections converge easily), this wasted
iterations; for D > 1000 with D-stepping, corrections must be reset to zero
(because the uncorrected solution is the correct starting point for the stepped D),
but the *uncorrected* solution must be saved separately as the initial guess for
the next case.

**Fix:** Carry C0_SAVE/E0_SAVE between cases for D <= 1000. For D > 1000, save
the uncorrected solution separately (PHI_UNCORR, W_UNCORR, OMEGA_UNCORR) and use
it as the initial guess when D-stepping resets corrections to zero.

**Result:** D = 2000 phi_M improved dramatically (3.10 -> 15.44, target 13.38).
D = 3500 overshot (49.33 vs 17.13). D = 5000 similar.

### T-0004: 2-cycle averaging stabiliser

**Problem:** The outer fixed-point iteration at D >= 2000 exhibited period-2
oscillation -- the iteration alternated between two states without converging.
This is a spectral property of the iteration operator (dominant eigenvalue near -1).

**Fix:** Added 2-cycle averaging: after each outer iteration, replace the solution
with the average of the current and previous iterates:
`x_{n+1} = (x_n + T(x_n)) / 2`. This kills the period-2 mode (eigenvalue -1 -> 0)
and damps the period-3 mode (eigenvalue magnitude -> 0.5). Applied to all three
fields including the wall boundary condition for Omega.

The averaging threshold differs by grid resolution:
- Grid (b) NR=20: needed for D >= 2000
- Grid (c) NR=40: needed for D >= 250 (finer grid resolves higher instability modes)

**Result:** All D values converged on both grids. Grid (c) matched C&D exactly:
D=3500 phi_M=17.13 (C&D 17.13), D=5000 phi_M=19.97 (C&D 19.97). However, w_M at
D=5000 had a 5% gap (427.7 vs C&D's 449.3) because the Fox corrections could only
absorb about 8% of their full value before the Picard iteration destabilised.

### T-0005: Anderson acceleration and NaN detection

**Problem:** At D = 5000, the Picard (fixed-point) iteration has a very narrow
basin of attraction. Fox corrections beyond ~8% of their full value caused the
iteration to diverge (NaN) or collapse to the trivial zero solution. The w_M gap
was 5% and could not be closed with any amount of under-relaxation.

**Approaches that failed** (v1-v12): heavy under-relaxation, restart-on-collapse,
wall-Omega convergence criteria, min-outer-iterations with NaN detection. Best
Picard result was w_M = 434.0 (3.4% gap).

**What worked:**
1. **Anderson acceleration** (Type-I, depth=4, damping beta=0.5): stores the last
   m outer iterates and residuals, solves a constrained least-squares problem for
   the optimal linear combination. Equivalent to GMRES on the fixed-point residual.
   Stabilises the iteration across all 692 correction iterations at D=5000.

2. **ieee_is_finite NaN detection**: added to SOR_PHI, SOR_W, SOR_OMEGA, and SMOOTH.
   Early exit on NaN prevents silent corruption (gfortran's MAX(a, NaN) returns a,
   making NaN invisible to convergence checks).

3. **Collapse detection**: after outer convergence, check if w_M dropped to less
   than 50% of the previous correction pass. If so, restore the previous state and
   declare corrections converged at the last good point.

4. **Dual convergence criteria**: primary (absolute residual < tolerance) for clean
   convergence at D <= 2000; secondary (98% relative reduction AND physical
   quantities stable to 0.1%) for D >= 3500 where corrections limit-cycle.

**Result:** D=5000 w_M=449.37 (C&D 449.3, 0.02% gap). All D values converge.
Full run completes in ~38 seconds.

### Grid merge: Single parameterised source

Originally, grid (b) and grid (c) were maintained as separate source files. As
grid (c) accumulated improvements (Anderson acceleration, NaN detection, correction
2-cycle averaging, collapse detection), the two files diverged by ~340 lines. The
files were merged into a single source with compile-time grid selection via
`INTEGER, PARAMETER :: NR, NA`. Grid-dependent parameters (MAXSOR, STEP_ITERS,
D_STEP, RHO_W, EPS_OUT, OMEGA1, averaging threshold) are selected by `IF (NR >= 40)`
blocks.

## Results

### Grid (b): NR=20, NA=36 (h=0.05, k=pi/36)

| D | phi_M | w_M | QR | C&D phi_M | C&D w_M |
|-------|--------|--------|---------|-----------|---------|
| 10 | 0.0119 | 2.50 | 0.9996 | -- | -- |
| 96 | 0.994 | 23.34 | 0.977 | 0.995 | 23.34 |
| 100 | 1.064 | 24.22 | 0.974 | -- | -- |
| 250 | 3.490 | 50.58 | 0.850 | -- | -- |
| 500 | 6.160 | 83.38 | 0.745 | 6.166 | 83.50 |
| 605.72 | 6.959 | 96.18 | 0.716 | 6.972 | 96.24 |
| 1000 | 9.308 | 140.62 | 0.640 | 9.308 | 140.6 |
| 2000 | 13.372 | 234.53 | 0.533 | 13.38 | 234.9 |
| 3500 | 17.469 | 347.20 | 0.453 | 17.13* | 351.4* |
| 5000 | 20.502 | 402.58 | 0.374 | 19.97* | 449.3* |

*C&D only report grid (c) results for D = 3500 and 5000. Grid (b) is too coarse
for these Dean numbers.

### Grid (c): NR=40, NA=72 (h=0.025, k=pi/72)

| D | phi_M | w_M | QR | C&D phi_M | C&D w_M | Gap |
|-------|---------|--------|---------|-----------|---------|------|
| 96 | 0.987 | 23.33 | 0.977 | 0.995 | 23.34 | -- |
| 500 | 6.117 | 83.66 | 0.748 | 6.166 | 83.66 | 0.0% |
| 1000 | 9.203 | 141.30 | 0.645 | 9.308 | 141.26 | 0.0% |
| 3500 | 17.115 | 351.24 | 0.462 | 17.13 | 351.4 | 0.05% |
| 5000 | 19.931 | 449.37 | 0.418 | 19.97 | 449.3 | 0.02% |

## Build and run

The code is a single-file Fortran 90 program with no external dependencies.

```bash
# Grid (b) -- default
gfortran -O2 -o cd_central Collins_Dennis_1975_central.f90
./cd_central

# Grid (c) -- edit line 303 to uncomment NR=4*10, comment out NR=2*10
gfortran -O2 -o cd_central_c Collins_Dennis_1975_central.f90
./cd_central_c
```

Output: results printed to stdout; solution fields saved to `cd_file_D*.dat` files.

## File structure

```
Collins_Dennis_1975_central.f90        Main solver (merged grid b/c)
Collins_Dennis_1975_central_C0only.f90 Variant with C0 correction only (E0=0)
Schubert_1972_complete_modern_Fortran.f90  Original upwind solver (Basse 2026)
verify_fox.py                          Algebraic verification of Fox corrections
background.md                         Basse (2026) paper summary
problem_description_for_chatgpt.md     Detailed derivation of correction formulae
attempts.md                           Pre-T-0001 debugging chronicle
almost-there.md                       Post-T-0004 status and gap analysis
still-struggling.md                   T-0005 v1-v12 debugging chronicle
wotan/backlog.json                    Task tracking
wotan/dev-log/T-0001..T-0005.md       Detailed task logs
```

## References

1. Dean WR. Note on the motion of fluid in a curved pipe. *Phil Mag.* 1927;4:208-23.
2. Dean WR. The stream-line motion of fluid in a curved pipe. *Phil Mag.* 1928;5:673-95.
3. Greenspan D, Schubert AB. Secondary flow in a curved tube. Univ. Wisconsin, CS Dept, Tech Report 155. 1972.
4. Greenspan D. Secondary flow in a curved tube. *J Fluid Mech.* 1973;57:167-76.
5. Collins WM, Dennis SCR. The steady motion of a viscous fluid in a curved tube. *Q. Jl Mech. appl. Math.* 1975;28(2):133-56.
6. Basse NT. Application of artificial intelligence to revive numerical studies of fluid motion in a curved pipe. *Discover Mechanical Engineering* 2026;5:21. DOI: [10.1007/s44245-026-00188-w](https://doi.org/10.1007/s44245-026-00188-w)
