# Almost There: Reviving Collins & Dennis (1975) Dean Flow Solver

## What This Project Is

This project implements the numerical method of Collins & Dennis (1975) for computing
steady laminar flow in a curved pipe (Dean flow) across the full range of Dean numbers
D = 10 to 5000. It builds on the modernised Schubert (1972) code from Basse (2026),
adding Fox's deferred correction to upgrade the W and Omega equations from first-order
upwind differencing to second-order central differencing.

The starting point was the `Schubert_1972_complete_modern_Fortran.f90` code from Basse's
paper, which correctly solves Dean flow with upwind differencing but cannot reproduce
the more accurate Collins & Dennis results because of the first-order truncation error
in the W and Omega equations.

### The physics in brief

Three coupled PDEs on a polar cross-section (r, alpha) of the pipe:

- **PHI** (stream function): Drives the secondary Dean vortices. Solved with
  central differencing (2nd order) even in the original Schubert code.
- **W** (axial velocity): The main flow down the pipe. Originally upwind (1st order).
- **Omega** (vorticity, = -nabla^2 PHI): Intermediate variable coupling PHI and W.
  Originally upwind (1st order).

The Dean number D = 4 Re sqrt(2a/L) controls the strength of the secondary flow.
At low D the flow is nearly Poiseuille; by D = 5000 the secondary vortices are
strong enough to significantly distort the axial velocity profile.

### What Collins & Dennis added

Rather than replacing the upwind stencils with central differences (which destroys
diagonal dominance and SOR convergence), C&D used Fox's deferred correction: solve
the upwind equations with frozen correction source terms C0 and E0 that represent
the difference between central and upwind discretisation. Iterate:

1. Solve upwind SOR with current C0, E0 as source terms
2. Compute new C0, E0 from the solution
3. Smooth-update: C0 += omega1 * (C0_new - C0_old)
4. Repeat

At convergence, the upwind truncation error is exactly cancelled by C0/E0, giving
central-difference accuracy with the stability of the upwind solver.


## Where We Started

The initial code (`Collins_Dennis_1975_central.f90`, commit `7a0279f`) implemented
Fox corrections and worked correctly for D <= 1000:

| D      | Our phi_M | C&D phi_M | Our w_M | C&D w_M | Match    |
|--------|-----------|-----------|---------|---------|----------|
| 96     | 0.994     | 0.995     | 23.34   | 23.34   | Excellent |
| 500    | 6.157     | 6.166     | 83.39   | 83.50   | Excellent |
| 605.72 | 6.962     | 6.972     | 96.20   | 96.24   | Excellent |
| 1000   | 9.308     | 9.308     | 140.60  | 140.6   | Exact     |

But **D >= 2000 was completely broken**: the outer iteration was trapped in a
persistent limit cycle, with phi_M oscillating wildly (e.g. between 7 and 65 at
D = 2000) and never converging.

### The root cause

The coupling loop PHI -> Omega_wall -> Omega_interior -> PHI has a gain
proportional to 2/h^2 = 800 (at grid spacing h = 0.05). At high D, the
secondary flow amplifies this feedback beyond the stability limit of the
sequential (Gauss-Seidel-like) outer iteration. No single under-relaxation
parameter XI(3) could fix this: low XI oscillates, high XI converges to the
trivial (zero) solution.


## What We Did (Steps A-F)

### Step A: Fix convergence checking (T-0001)

**Problem**: The convergence test in SMOOTH measured the *relaxed* update
`(1-XI) * (raw - old)`, not the raw update. With large XI (heavy damping),
this made the convergence check see artificially small changes, causing false
convergence to under-developed solutions.

**Fix**: Changed all convergence checks (SMOOTH, W-origin, Omega-wall) to test
against `XIC * EPS` so that EPS refers to the unrelaxed update magnitude.

### Step B: Wall BC residual diagnostic (T-0001)

Added `RES_WALL = max|Omega_wall + 2/h^2 * PHI_interior|` as a diagnostic
printed alongside the existing DIAG output. This made it immediately visible
when the wall boundary condition was not being satisfied, which was critical
for debugging the high-D instability.

### Step C: Stabilised XI parameters (T-0001)

With the convergence check fixed, heavy damping no longer causes false convergence.
Tuned XI parameters for D >= 2000 to damp all coupled fields (not just the wall BC):

```
D=2000: XI = (0.85, 0.50, 0.90, 0.85)   ! PHI, W, wall, Omega-interior
D=3500: XI = (0.90, 0.60, 0.93, 0.90)
D=5000: XI = (0.93, 0.65, 0.95, 0.93)
```

**Result**: D <= 1000 unchanged. D >= 2000 no longer converges to trivial, but
still oscillates (phi_M in the right ballpark but not converging).

### Step D: Consistent Omega SOR boundaries (T-0002)

**Problem**: Only the wall boundary `OMEGA(NRP1,:,2)` was being copied to the
SOR "old iterate" slice before SOR_OMEGA. The r=0, alpha=0, and alpha=pi
boundaries on slice 2 were stale from program initialisation.

**Fix**: Copy all four boundary frames to slice 2 before each SOR_OMEGA call.

**Result**: No change in output (boundaries happened to be zero = correct for
these cases), but eliminates a latent bug.

### Step E: Carry Fox corrections between D cases (T-0003)

**Problem**: At each new D case, C0_CORR and E0_CORR were reset to zero, forcing
the correction iteration to relearn everything from scratch — especially costly
at high D where the correction smoothing factor omega1 is small (0.01-0.1).

**Fix**: Save corrections from each case and use them as initial guess for the
next case.

**Result**: D = 2000 phi_M improved dramatically (3.10 -> 15.44, target 13.38).
D = 3500 overshot (49.33). Still oscillating, but clearly closer.

### Step F: 2-cycle averaging stabiliser (T-0004)

This was the breakthrough.

**Problem**: The outer iteration at D >= 2000 has a dominant eigenvalue near -1,
producing period-2 oscillation that no amount of under-relaxation can fix
(under-relaxation scales ALL eigenvalues, not just the problematic one).

**Fix**: After each outer iteration, average the start-of-iteration fields
(slice 1) with the end-of-iteration fields (slice 3):

```fortran
PHI(:,:,3)   = 0.5 * (PHI(:,:,1)   + PHI(:,:,3))
W(:,:,3)     = 0.5 * (W(:,:,1)     + W(:,:,3))
OMEGA(:,:,3) = 0.5 * (OMEGA(:,:,1) + OMEGA(:,:,3))
```

Mathematically: x_{n+1} = (x_n + T(x_n)) / 2, where T is the outer iteration
operator. This maps eigenvalue -1 to 0 (kills period-2 oscillation) and maps
eigenvalue e^{2*pi*i/3} to magnitude 0.5 (damps period-3 oscillation). It
leaves eigenvalue +1 (the fixed point) unchanged.

**Additional required changes**:

1. **Post-averaging convergence check (EPS_OUT)**: The existing SMOOTH-based
   convergence check happens before averaging and doesn't reflect the averaged
   state. Added a MAXVAL-based check on the difference between slice 1 and
   slice 3 after averaging. Uses looser thresholds for D >= 3500 where the
   grid is too coarse for tight convergence.

2. **Uncorrected solution handoff**: D-stepping (continuation from lower D)
   resets corrections to zero. If the initial guess comes from a Fox-corrected
   solution, the mismatch causes D-stepping to crash. Fixed by saving the
   uncorrected (pre-Fox) solution and using that as the initial guess for the
   next case.

3. **OMEGA1 = 0 for D = 5000**: On both grids, Fox corrections at D = 5000
   destabilise the outer iteration. Setting omega1 = 0 (no corrections) gives
   the upwind solution, which still has excellent phi_M accuracy.


## Where We Are Now

### Grid (b) results (NR=20, NA=36, h=0.05, k=pi/36) — our standard grid

| D      | Our phi_M | C&D phi_M | Our w_M | C&D w_M | Status    |
|--------|-----------|-----------|---------|---------|-----------|
| 10     | 0.0119    | --        | 2.50    | --      | PASS      |
| 96     | 0.9939    | 0.995     | 23.34   | 23.34   | PASS      |
| 100    | 1.0643    | --        | 24.21   | --      | PASS      |
| 250    | 3.4904    | --        | 50.59   | --      | PASS      |
| 500    | 6.1567    | 6.166     | 83.38   | 83.50   | PASS      |
| 605.72 | 6.9619    | 6.972     | 96.19   | 96.24   | PASS      |
| 1000   | 9.3057    | 9.308     | 140.59  | 140.6   | PASS      |
| 2000   | 13.3633   | 13.38     | 233.84  | 234.9   | PASS      |
| 3500   | 17.5243   | 17.13*    | 341.79  | 351.4*  | CONVERGED |
| 5000   | 20.3904   | 19.97*    | 398.13  | 449.3*  | CONVERGED |

*C&D values for D=3500 and D=5000 are from grid (c), not grid (b). Some
difference is expected.

### Grid (c) results (NR=40, NA=72, h=0.025, k=pi/72) — C&D's fine grid

| D      | Our phi_M  | C&D phi_M  | Our w_M | C&D w_M | Status    |
|--------|------------|------------|---------|---------|-----------|
| 96     | 0.9865     | 0.995      | 23.34   | 23.34   | OK        |
| 500    | 6.1153     | 6.166      | 83.66   | 83.50   | OK        |
| 1000   | 9.2120     | 9.308      | 141.26  | 140.6   | OK        |
| 2000   | 13.1855    | 13.38      | 235.95  | 234.9   | OK        |
| 3500   | **17.1275** | **17.13** | 347.91  | 351.4   | CONVERGED |
| 5000   | **19.9724** | **19.97** | 427.84  | 449.3   | CONVERGED |

Grid (c) needed different solver parameters vs grid (b):
- 2-cycle averaging from D >= 250 (vs D >= 2000 on grid b)
- MAXSOR = 50000 (vs 2500)
- D_STEP = 5 (vs 10), STEP_ITERS = 40 (vs 20)
- RHO_W = 1.5 for D >= 3500 (RHO_W = 1.7 diverges at D ~ 3015 on grid c)
- OMEGA1 = 0 for D = 5000, with very loose EPS_OUT

### Summary: phi_M is solved, w_M has a gap at high D

**phi_M** (stream function maximum) matches C&D across the full range:
- D <= 2000: within 0.2% on grid (b)
- D = 3500: **exact match** on grid (c) (17.13 vs 17.13)
- D = 5000: **exact match** on grid (c) (19.97 vs 19.97)

**w_M** (axial velocity maximum) matches well for D <= 2000 but has a growing
gap at high D:
- D <= 1000: within 0.2% on grid (b)
- D = 2000: within 0.5% on grid (b) (233.8 vs 234.9)
- D = 3500 grid (c): 1% low (347.9 vs 351.4) — Fox corrections partially converged (30 iterations)
- D = 5000 grid (c): **5% low (427.8 vs 449.3)** — Fox corrections skipped entirely (OMEGA1 = 0)


## What Remains: Closing the w_M Gap

The w_M discrepancy at D = 3500 and D = 5000 comes from one cause: **Fox
corrections at high D destabilise the outer iteration**.

At D = 3500, we can run 30 correction iterations and get partial convergence
(w_M improves from 316 uncorrected to 348, target 351). At D = 5000, even
OMEGA1 = 0.0005 causes divergence, so we get only the upwind solution (w_M = 428
vs central-difference target 449).

This matters because phi_M depends mainly on the stream function equation (which
uses central differencing natively) while w_M depends on the W equation (which
needs Fox corrections to achieve central-difference accuracy). Without fully
converged corrections, w_M retains some upwind truncation error.

### Why this is hard

The Fox correction terms C0 and E0 act as additional source terms in the SOR.
When they change between correction iterations, the outer iteration must
re-converge. At high D, the outer iteration is already near its stability limit
(hence the need for 2-cycle averaging). Adding correction perturbations pushes
it over the edge.

C&D presumably solved this, but their paper gives no details about the iteration
strategy at high D beyond mentioning "continuation in D" and "correction smoothing".

### Possible approaches

1. **More correction smoothing iterations at D = 3500**: Currently limited to 30.
   Increasing to 100+ might fully converge w_M, if the outer iteration remains
   stable. Need to check whether the correction residual is still decreasing at
   iteration 30.

2. **Defect correction with strong damping**: Instead of iterating C0/E0 within
   the solver, compute corrections from a fully converged upwind solution, apply
   a fraction, re-converge, repeat. This separates the correction update from
   the outer iteration stability.

3. **Richardson extrapolation**: Run on grids (b) and (c) without corrections
   and extrapolate to h -> 0. Since the upwind scheme is O(h), two grids suffice
   for O(h^2) accuracy. This avoids Fox corrections entirely.

4. **GMRES or Anderson acceleration on the outer iteration**: Replace the simple
   fixed-point iteration (with 2-cycle averaging) with a Krylov-accelerated
   method that can handle multiple unstable eigenvalues simultaneously. This
   would make the outer iteration robust enough to tolerate correction perturbations.

5. **Implicit correction coupling**: Instead of freezing C0/E0 and re-solving,
   linearise the correction terms and fold them into the SOR coefficients. This
   makes the SOR solve the central-difference equations directly, but requires
   reworking the SOR to handle the modified stencil (which may lose diagonal
   dominance at high D).

6. **Grid refinement study**: Run grid (b), (c), and a finer grid (d) without
   corrections. Use Richardson extrapolation on w_M to estimate the h -> 0
   limit. This would tell us whether the grid (c) uncorrected w_M = 428 is
   consistent with the corrected target of 449.


## Project Files

### Source code
- `Collins_Dennis_1975_central.f90` — Main solver, grid (b) parameters (1093 lines)
- `Collins_Dennis_1975_central_gridc.f90` — Grid (c) variant with adjusted parameters (1093 lines)
- `Schubert_1972_complete_modern_Fortran.f90` — Original Basse (2026) code, upwind only

### Compiled binaries
- `cd_central` — Grid (b) solver
- `cd_central_c` — Grid (c) solver

### Reference materials
- `qjmam%2F28.2.133.pdf` — Collins & Dennis (1975) paper
- `s44245-026-00188-w.pdf` — Basse (2026) paper
- `44245_2026_188_MOESM1_ESM.pdf` — Basse supplementary material (code appendices)
- `background.md` — Detailed background notes
- `attempts.md` — Chronicle of failed approaches for D >= 2000 (pre-Steps A-F)

### Task management
- `wotan/backlog.json` — Task index (T-0001 through T-0004, all DONE)
- `wotan/dev-log/T-{0001..0004}.md` — Detailed task logs

### Output files
- `cd_output_T0001.txt` through `cd_output_T0004b.txt` — Solver output at each task stage
- `run_gridc{1..6}.txt` — Grid (c) solver output across parameter iterations
- `cd_file_D*.dat` — Solution field data for each D value


## Commit History

```
99a1427 Initial commit: Dean flow solver and reference materials
7a0279f Add Fox deferred correction solver matching Collins & Dennis (1975) for D <= 1000
271219f T-0001: Fix convergence checking, add wall BC diagnostic, stabilise high-D XI
ced344f T-0002: Propagate all Omega boundaries to SOR slice 2
6d19af9 T-0003: Carry Fox corrections between D cases
4ed46cd T-0004: Add 2-cycle averaging stabiliser for D>=2000
```
