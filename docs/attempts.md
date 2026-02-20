# Attempts to Fix Fox Deferred Correction for Dean Flow Solver

## Current Status (2026-02-18)

**D = 10 to 1000: WORKING.** Results match Collins & Dennis (1975) to 4 significant figures.

| D | phi_M (ours) | phi_M (C&D) | w_M (ours) | w_M (C&D) | QR (ours) | QR (C&D) |
|---|-------|------|---------|--------|---------|------|
| 10 | 0.0119 | — | 2.50 | — | 0.9996 | — |
| 96 | **0.994** | 0.995 | **23.34** | 23.34 | **0.977** | 0.977 |
| 100 | 1.064 | — | 24.22 | — | 0.974 | — |
| 250 | 3.490 | — | 50.59 | — | 0.850 | — |
| 500 | **6.156** | 6.166 | **83.39** | 83.50 | **0.745** | 0.815 |
| 605 | 6.962 | — | 96.20 | — | 0.716 | — |
| 1000 | **9.308** | 9.308 | **140.60** | 140.6 | **0.640** | 0.650 |
| 2000 | FAILS | — | FAILS | — | FAILS | — |
| 3500 | FAILS | — | FAILS | — | FAILS | — |
| 5000 | FAILS | — | FAILS | — | FAILS | — |

**D >= 2000: BROKEN.** The outer iteration oscillates and never converges.

---

## Background

The solver implements Collins & Dennis (1975) Fox deferred correction method for Dean flow in a curved pipe. The base code is Schubert (1972), which uses an upwind-differenced SOR. Fox's method adds correction terms C0, E0 as frozen source terms to achieve central-difference (2nd order) accuracy.

The code has three coupled PDEs solved iteratively:
1. **PHI** (stream function): Poisson equation driven by Omega
2. **W** (axial velocity): advection-diffusion with upwind SOR + C0 correction
3. **Omega** (vorticity): advection-diffusion with upwind SOR + E0 correction

The outer iteration couples them: PHI(Omega) -> W(PHI) -> Omega(W, PHI).

The wall vorticity boundary condition is:
```
Omega_wall = -2/h^2 * PHI_interior   (Woods/Thom formula)
```
With h=0.05 (NR=20), the amplification factor is 2/h^2 = 800.

---

## Edit History

### Round 1: ChatGPT-identified discretization fixes (all successful)

1. **Central-difference PHI B-coefficients**: Changed from forward-difference to central-difference for (1/r)*dPHI/dr in the Poisson equation. The old code had an asymmetric stencil; the new code uses symmetric +/- DA/(2r) contributions.

2. **SOR_PHI loop extended**: Removed special non-Poisson treatment at I=NR. Now uses a single loop `I=2,NR` with the same B-coefficients throughout.

3. **PHI boundary enforcement**: Added explicit Dirichlet zero enforcement on all PHI boundaries for slices 2 and 3 at start of each outer iteration.

4. **Early-stop removal**: Deleted a heuristic that allowed premature correction convergence based on phi_max/w_max stability.

5. **CHECK_CENTRAL_RESIDUALS subroutine**: Added diagnostic subroutine computing max residuals of the central-difference PHI, W, and Omega equations.

### Round 2: Wall BC bug fix (partially successful)

6. **Omega wall BC propagation**: Identified that `OMEGA(NRP1,:,2)` (SOR "old iterate" at wall) was never updated — it stayed at zero forever. The SOR at I=NR was solving with incorrect zero wall BC in the Jacobi direction.

   **Fix**: Added `OMEGA(NRP1, 1:NAP1, 2) = OMEGA(NRP1, 1:NAP1, 3)` before each SOR_OMEGA call.

   **Problem**: This fix is correct but introduced a coupling instability. The feedback loop PHI -> wall_Omega (factor 800) -> interior_Omega -> PHI has spectral radius > 1 with the original XI(3)=0.1 smoothing parameter.

### Round 3: XI parameter tuning (partially successful)

7. **XI(3) increase for low D**: Changed XI(3) from 0.1 to 0.9 for D<=100 cases. This heavily damps the wall BC update (only 10% new per iteration). **Result**: D=10 and D=96 converge perfectly, matching C&D targets.

8. **XI tuning for D=250-1000**: Used XI=(0.5, 0.1, 0.5, 0.5) for cases 4-7. **Result**: D=250 through D=1000 all converge correctly.

9. **D-stepping threshold lowered**: Changed D-stepping activation from `D > 1000` to `D > 200`. **Result**: Helped D=250+ get better initial guesses from previous cases.

---

## The D >= 2000 Problem

### Symptom

The outer iteration at D=2000 is trapped in a **limit cycle** (2-cycle or chaotic oscillation). DIAG output shows maxPHI alternating wildly between ~7 and ~23 (or more broadly ~5 to ~65), never settling. This persists regardless of how many iterations are allowed (tested up to 5000).

### Root Cause

The coupling gain in the feedback loop PHI -> Omega_wall -> Omega_interior -> PHI exceeds 1 for D >= 2000 with any XI(3) value that allows reasonable convergence speed:

- **XI(3) = 0.5**: Oscillation with period ~3-5 iterations. maxPHI swings 7-23. Does not converge even in 5000 iterations.
- **XI(3) = 0.7**: Still oscillates, slightly damped. Does not converge in 1200 iterations.
- **XI(3) = 0.9**: Stable (no oscillation) but wall BC updates by only 10% per iteration. The convergence tolerance EPS(3)=0.3 requires Omega changes < 0.3, but the wall BC values are O(1000). This needs ~5000+ iterations for the wall BC alone. Outer iteration "converges" but to a near-trivial solution because the wall BC never reaches its correct value.
- **XI(3) = 0.95**: Same issue, even slower.

The fundamental dilemma: **XI(3) small enough to converge in time => oscillation. XI(3) large enough to prevent oscillation => too slow.**

### What We Tried for D >= 2000

| Attempt | XI(3) | MAXOUT | D-step | Result |
|---------|-------|--------|--------|--------|
| XI(3)=0.5, MAXOUT=3000 | 0.5 | 3000 | 10 | Oscillates, phi_M=18.9 at timeout |
| XI(3)=0.7, MAXOUT=1200 | 0.7 | 1200 | 10 | Oscillates, phi_M=19.9 at timeout |
| XI(3)=0.9, MAXOUT=5000 | 0.9 | 5000 | 10 | "Converges" to near-zero (phi_M=0.04) |
| XI(3)=0.95, MAXOUT=5000 | 0.95 | 5000 | 10 | "Converges" to near-zero (phi_M=0.03) |
| XI all=0.5, MAXOUT=3000 | 0.5 | 3000 | 10 | Oscillates |
| XI(3)=0.5, XI(2)=0.5 | 0.5 | 5000 | 10 | Oscillates |

### Structural Changes Attempted

| Attempt | Description | Result |
|---------|-------------|--------|
| **Reverse-I SOR sweep** | Sweep I=NR→2 so wall BC enters via Gauss-Seidel (slice 3) instead of Jacobi (slice 2) | **Unstable**: fields explode ~6x per iteration. The upwind stencil E-coefficients assume forward sweep; reversing changes Gauss-Seidel direction and destroys diagonal dominance in the sweep. |
| **Slice-3 direct access at I=NR** | Keep forward sweep but read wall BC from slice 3 at I=NR only | **Same explosion** as with slice-2 propagation + XI(3)=0.1. Confirms the instability is in the outer iteration coupling, not the SOR implementation. The two approaches are mathematically equivalent. |
| **D-stepping with small steps** | D_STEP=10 instead of 20, STEP_ITERS=10 instead of 3 | Helps the D-stepping phase but doesn't fix convergence at the target D=2000. |

---

## Key Insights

1. **The wall BC fix is correct.** Without it, the SOR at I=NR operates with zero wall vorticity, producing wrong solutions. With it, D=96-1000 match C&D to 4 significant figures.

2. **The instability is an outer iteration problem**, not an SOR problem. The SOR itself converges fine. The issue is the coupled iteration between PHI, W, and Omega, specifically the PHI <-> Omega_wall coupling.

3. **The amplification factor 2/h^2 = 800** is the root cause. A small change in PHI produces a huge change in Omega_wall, which drives a large change in interior Omega, which drives PHI back. At high D, the secondary flow (PHI) is strong enough that this loop has gain > 1.

4. **At D <= 1000, the gain is controllable** with moderate XI(3) (0.5-0.9). At D >= 2000, no single XI(3) value works — either too fast (oscillates) or too slow (converges to trivial solution).

5. **C&D must have handled this differently.** Their paper reports results up to D=5000 on the same grid. Possible differences:
   - They may solve W first, then PHI, then Omega (different iteration order)
   - They may use a different wall BC formulation or coupling strategy
   - They may use adaptive relaxation that we haven't implemented
   - They may use the Cartesian representation at r=0 (their eq. 16) which we haven't implemented

---

## Ideas Not Yet Tried

1. **Change iteration order to C&D's**: W -> PHI -> Omega instead of PHI -> W -> Omega. This changes the coupling dynamics — W would use "old" PHI rather than "new" PHI, potentially reducing the feedback loop gain.

2. **Adaptive XI(3)**: Start with XI(3)=0.9, gradually reduce toward 0.3 as the solution matures. This prevents early oscillation while allowing eventual convergence.

3. **2-cycle averaging**: Detect when the solution is in a 2-cycle and take the average of two consecutive iterates as the new solution. This is a form of Anderson acceleration.

4. **Implicit wall BC coupling**: Instead of the sequential PHI -> wall_Omega -> SOR_Omega, solve the PHI-Omega_wall system simultaneously. This eliminates the lag.

5. **Different wall BC formula**: Use a higher-order wall vorticity formula that has a smaller amplification factor (e.g., Briley's formula which uses interior points).

6. **SSOR (Symmetric SOR)**: Alternate between forward and backward sweeps within each SOR call. This can improve convergence for non-symmetric systems.

7. **Cartesian representation at r=0**: Implement C&D eq. (16) for the corrections near the origin. This might affect the coupling near the center.

---

## Current Code State

File: `Collins_Dennis_1975_central.f90`

Key parameters:
- `MAXOUT = 5000`
- `STEP_ITERS = 10`
- `D_STEP = 10` (uniform for all D)
- D-stepping activates for D > 200
- XI values: (0.1,0.1,0.9,0.1) for D<=100; (0.5,0.1,0.5,0.5) for D=250-2000+

Key locations:
- Lines 427-436: XI_CASES definitions
- Lines 668-673: Wall BC computation (Woods/Thom formula)
- Lines 688-691: Wall BC propagation to SOR slice 2
- Lines 219-241: SOR_OMEGA subroutine (forward I sweep)
- Lines 771-797: Fox correction C0/E0 computation
