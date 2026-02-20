# The D=5000 Fox Correction Problem

## Background

We are implementing the Dean flow solver from Collins & Dennis (1975), which computes steady secondary flow in a curved pipe. The solver uses three coupled fields:

- **PHI** (stream function for secondary flow)
- **W** (axial velocity)
- **OMEGA** (vorticity)

The Dean number **D** controls the flow regime. At low D (laminar), the equations are well-behaved. At high D (D=3500, D=5000), the nonlinear coupling is strong and the numerical iteration becomes marginally stable.

### The Fox Deferred Correction Method

The solver uses **upwind differencing** for diagonal dominance in the SOR (Successive Over-Relaxation) inner solves. Upwind differencing is only first-order accurate. To recover second-order (central-difference) accuracy, C&D apply **Fox's deferred correction method**:

1. Solve the upwind-discretized equations to convergence (outer Picard iteration)
2. Compute the **truncation error corrections** C0 (for W eq.) and E0 (for Omega eq.) from the converged solution
3. Add these corrections as source terms to the upwind equations
4. Re-solve to convergence with the updated source terms
5. Repeat until the corrections stabilize

The corrections are smoothed with parameter omega_1 (C&D eq. 21):
```
C0_CORR = omega_1 * C0_NEW + (1 - omega_1) * C0_OLD
```
C&D use omega_1 = 0.05 for most D values, omega_1 = 0.01 for D=5000.

### What Matches

Our solver reproduces C&D's results exactly for **phi_M** (stream function maximum) at ALL Dean numbers, and for **w_M** (axial velocity maximum) at D ≤ 2000. The corrections converge cleanly at these lower D values.

At D=3500 on grid (c), after extensive work (T-0004 + T-0005), we now get:
- phi_M = 17.11 (C&D: 17.13) — excellent
- w_M = 351.3 (C&D: 351.4) — excellent (0.03% gap)

### The Problem: D=5000

At D=5000, the **uncorrected** solution gives:
- phi_M = 19.97 (C&D: 19.97) — matches perfectly
- w_M = 427.7 (C&D: 449.3) — **5% low** (upwind truncation error)

The phi_M match shows the stream function is correct. The w_M gap is entirely due to the Fox corrections not converging — without corrections, the upwind scheme under-predicts the axial velocity peak by 5%.

**Target**: w_M = 449.3 (C&D Table 2, grid c)
**Current best**: w_M = 434.0 (after 8 partial correction iterations)

## Root Cause Analysis

The outer Picard iteration at D=5000 is **marginally stable**. The nontrivial Dean flow solution coexists with the trivial zero solution, and the iteration basin of attraction is narrow. When Fox corrections are added as source terms, they perturb the iteration enough to push it out of the basin, causing either:

1. **Divergence to NaN** — the SOR inner solve blows up
2. **Collapse to the trivial zero solution** — the iteration converges but to the wrong fixed point

### Why D=5000 is Different from D=3500

At D=3500, the corrections are moderate and the iteration is stable enough to absorb them. The correction residuals enter a limit cycle (period-2 oscillation), but 2-cycle averaging + physical convergence criteria handle this.

At D=5000, the correction amplitudes are larger (res C0 ~ 5.0 vs ~0.5 at D=3500) and the iteration is more fragile. The accumulated corrections after ~8 iterations at omega_1=0.01 (accumulating ~8% of the full correction) are enough to destabilize the outer iteration.

### Additional Complication: NaN Invisibility

We discovered that gfortran's `MAX(a, NaN)` returns `a` (not NaN), making NaN values invisible to convergence checks that use MAX-norm. When the SOR diverges to NaN, the correction residuals appear as zero, the convergence check "succeeds" trivially, and the solver reports phi_M=0, w_M=0 (since `NaN > 0` is FALSE in IEEE 754). We now detect NaN via `SUM(ABS(array))` which does propagate NaN.

## What We Have Tried

### Successfully Fixed (D=3500)

1. **Fixed correction convergence metric** — The original code tracked the *damped* residual `omega_1 * |C0_NEW - C0_OLD|` instead of the *undamped* residual `|C0_NEW - C0_CURRENT|`. With omega_1=0.05, the damped metric is 20x smaller than the true residual, declaring convergence prematurely.

2. **Increased MAX_CORR from 30 to 400** — At omega_1=0.05, 30 iterations accumulate only 78% of the correction. 400 iterations allow near-complete accumulation.

3. **Added 2-cycle averaging for correction NEW values** — The outer iteration's period-2 oscillation cascades into the correction computation, causing C0_CORR_NEW to oscillate. Averaging consecutive raw values kills the period-2 component.

4. **Dual convergence criterion** — Primary: absolute undamped residual < CORR_TOL. Secondary: 99% relative residual reduction + physical stability (w_M and phi_M change < 0.1%). The secondary criterion catches the limit-cycle case at D=3500 where absolute convergence is never reached but the solution has stabilized.

### Attempted for D=5000

#### v1: Wall-Omega Convergence Criterion + Tight EPS_OUT
- **Idea**: Use C&D's own convergence criterion (wall-Omega change < 1e-4) and tight EPS_OUT
- **Result**: D=3500 FAILED (wall-Omega too tight with 2-cycle averaging). D=5000 collapsed to zero solution (tight EPS_OUT lets the iteration escape to the trivial fixed point).
- **Lesson**: Our 2-cycle averaging changes the iteration dynamics vs. C&D's original method.

#### v7: Heavy Under-Relaxation + Gauss-Seidel (Plan Phase 3b+3c)
- **Idea**: During correction iterations at D≥5000, use XI=(0.9, 0.6, 0.93, 0.9) and RHO_W=1.0 (Gauss-Seidel instead of SOR)
- **Result**: D=5000 DIVERGED — phi_M grew from 20 to 29, solution unstable
- **Lesson**: Heavy damping made things worse, not better.

#### v10: NaN-Aware Collapse Detection + Restore
- **Idea**: Detect NaN/collapse via `W_CUR_MAX /= W_CUR_MAX` (NaN self-inequality), restore previous good state
- **Result**: Detection works! D=5000 restores to w_M=427.66 after 12 correction iterations.
- **Limitation**: Only 12 correction iterations before divergence, accumulating ~12% of full correction.

#### v11: Minimum Outer Iterations During Corrections
- **Idea**: The loose EPS_OUT=(1, 10, 100) for D=5000 lets the outer converge in just 2 iterations, so the solution doesn't equilibrate with corrections. Force minimum 10 outer iterations during correction passes.
- **Result**: D=5000 w_M improved from 427.66 to 433.96! But NaN hits earlier (8 correction iterations vs 12).
- **Trade-off**: Tighter outer convergence helps the solution adapt to corrections but amplifies instability.

#### v11b: Restart-on-Collapse
- **Idea**: After NaN detection, restore to last good state and restart the correction loop (keeping accumulated C0_CORR). The corrections recomputed from the improved solution should be smaller.
- **Result**: FAILED — restart 1 immediately NaNs again because the accumulated corrections are at the stability limit. Restart 2's outer iteration produces NaN at boundary points not caught by interior-only diagnostics.
- **Lesson**: The correction level itself is the problem, not just the iteration trajectory. Once corrections reach ~8% of full, the outer iteration can't converge.

### Current Best (v12)

Combines: min-10-outer-iterations + NaN-aware collapse detection + restore-and-exit.

| D | phi_M | w_M | C&D | Gap |
|---|-------|------|-----|-----|
| 3500 | 17.11 | 351.3 | 351.4 | 0.03% |
| 5000 | 20.09 | 434.0 | 449.3 | 3.4% |

## What Remains Untried

### Phase 3a: Correction Homotopy (CORR_SCALE Ramping)
Instead of applying the full accumulated corrections at once, ramp a scale factor from 0 to 1:
```fortran
W_source = (DDRDAM + CORR_SCALE * C0_CORR(I,J)) / diagonal
```
This lets the outer iteration adapt gradually. Different from omega_1 smoothing which controls the *accumulation rate* — CORR_SCALE controls the *applied fraction*.

### Phase 4: Anderson Acceleration
Replace the outer Picard iteration (x_{n+1} = T(x_n)) with Anderson mixing:
- Store last m iterates and residuals
- Solve small m×m least-squares for optimal linear combination
- Equivalent to GMRES on the fixed-point residual
- Proven to improve convergence for NS Picard at high Re (Pollock et al. 2019)
- Can converge to unstable fixed points that Picard cannot
- Memory: m × n × 8 bytes ≈ 700 KB for m=10 on grid (c)
- This is the "nuclear option" but essentially guaranteed to work.

### Smaller omega_1
Using omega_1=0.005 instead of 0.01 would slow accumulation but allow more iterations before instability. However, linear extrapolation suggests this can't bridge the full gap — the issue is the ~8% stability ceiling, not the accumulation rate.

### Alternative Inner Solver
The SOR is the weakest link — it diverges first. A direct solver (banded LU) or a more robust iterative solver (BiCGSTAB, GMRES) for the inner W equation could tolerate larger corrections without diverging.

## Key Insight

The fundamental problem is that **the outer Picard iteration at D=5000 has a very narrow basin of attraction for the nontrivial Dean flow solution**. The Fox corrections, while mathematically correct, push the iteration out of this basin. C&D presumably had a stable iteration because they:
1. Used the parabolic formula at the wall (we use full stencil + 2-cycle averaging)
2. Did NOT use 2-cycle averaging (their wall BC under-relaxation was sufficient)
3. May have had other stabilization tricks not documented in the paper

The 2-cycle averaging is essential for our full-stencil approach but changes the iteration dynamics in ways that reduce the stability margin at high D.

**The most promising path forward is Anderson acceleration (Phase 4)**, which fundamentally changes the iteration convergence properties rather than trying to work within the narrow stability margin of Picard iteration.
