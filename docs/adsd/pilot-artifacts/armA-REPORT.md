# REPORT: second-order (deferred-correction) Dean-flow solver

`gfortran -O2 -o solver solver.f90 && ./solver` runs in about 93 s on this machine
and prints:

```
RESULT D=96.00 PHI_M=.9943 W_M=23.344 STATUS=CONVERGED
RESULT D=500.00 PHI_M=6.1583 W_M=83.400 STATUS=CONVERGED
RESULT D=605.72 PHI_M=6.9619 W_M=96.201 STATUS=CONVERGED
RESULT D=1000.00 PHI_M=9.3059 W_M=140.591 STATUS=CONVERGED
RESULT D=2000.00 PHI_M=13.3691 W_M=234.524 STATUS=CONVERGED
RESULT D=3500.00 PHI_M=17.4756 W_M=347.234 STATUS=CONVERGED
RESULT D=5000.00 PHI_M=20.4271 W_M=443.990 STATUS=CONVERGED
```

## Final results table

| D | phi_M (this) | phi_M (C&D) | diff | w_M (this) | w_M (C&D) | diff | C&D grid |
|---|---|---|---|---|---|---|---|
| 96     | 0.9943  | 0.995 | −0.07 % | 23.344  | 23.34 | +0.02 % | h = 0.05 |
| 500    | 6.1583  | 6.166 | −0.12 % | 83.400  | 83.50 | −0.12 % | h = 0.05 |
| 605.72 | 6.9619  | 6.972 | −0.14 % | 96.201  | 96.24 | −0.04 % | h = 0.05 |
| 1000   | 9.3059  | 9.308 | −0.02 % | 140.591 | 140.6 | −0.01 % | h = 0.05 |
| 2000   | 13.3691 | 13.38 | −0.08 % | 234.524 | 234.9 | −0.16 % | h = 0.05 |
| 3500   | 17.4756 | 17.13 | +2.0 %  | 347.234 | 351.4 | −1.2 %  | h = 0.025 only |
| 5000   | 20.4271 | 19.97 | +2.3 %  | 443.990 | 449.3 | −1.2 %  | h = 0.025 only |

On the same grid, every value agrees with C&D to 0.16% or better. At D=3500 and 5000
the reference values come from C&D's finer grid, and phi_M is within 2.3% of them. All
cases reach the deferred-correction convergence criterion.

For comparison, switching the correction off (`./solver upwind`) gives the first-order
upwind values with the same boundary conditions. For example, D=1000 gives 9.0834 /
130.755 and D=5000 gives 20.52 / 401.5. So the correction changes w_M by 7–10% at
higher D, and it moves the result onto the C&D numbers.

## What the code does (mapping of the C&D formulae)

Schubert's W and OMEGA equations, multiplied through by h·k, read

    (k/h)(W_E+W_W-2W_0) + (h/(k r^2))(W_N+W_S-2W_0)
      + (1/r)[max(Δ,0)(W_E-W_0) - min(Δ,0)(W_W-W_0) + max(Γ,0)(W_N-W_0) - min(Γ,0)(W_S-W_0)]
      + D h k = 0

with `GAMMA = Γ = (PHI_E-PHI_W)/2` and `DELTA = Δ = k - (PHI_N-PHI_S)/2`. Here Δ
includes the Laplacian's (1/r)∂/∂r term. The upwind bracket equals the central
difference (Δ(W_E−W_W) + Γ(W_N−W_S))/2 plus (|Δ|δ²_r W + |Γ|δ²_α W)/2. In this
normalisation, C&D's

    C_0 = -(1/2r) [ |Δ|(W_E+W_W-2W_0) + |Γ|(W_N+W_S-2W_0) ]

is therefore exactly the term to add to the source. That means `E(I,J,5) = (D h k + C_0)/E(I,J,6)`,
and E_0 enters the OMEGA source `E(I,J,6)` in the same way. The correction is also applied on the
symmetry lines α = 0 and α = π, where Γ = 0, Δ = k ∓ PHI(I,2 or NA), and the denominators are
EE1/EE2. It is also applied at the origin (scaled by h², using PHI(2,NAH)).

The program has two levels:

1. With C_0 and E_0 frozen, it runs Schubert's outer iteration (SOR for PHI, W and OMEGA,
   with smoothing) until the changes fall below 1e-7 relative to the field maxima.
2. It then computes new corrections from the converged fields and blends them with
   `C_0 <- ω1 C_0new + (1−ω1) C_0`. ω1 is 0.5 for D < 1500 and 0.3 above. It stops when
   the relative change in both corrections is below 1e-5 and phi_M and w_M have
   stopped changing (1e-6 relative). This takes 22–84 correction cycles per D.

The PHI equation uses central differences throughout. Schubert used a one-sided
difference for the (1/r)∂PHI/∂r term.

Continuation in D goes through the intermediate (unreported) values 200, 300, 400, 800,
1250, 1500, 1750, 2500, 3000 and 4250. A wall-clock guard at 540 s marks any remaining
cases FAILED, so the run can never exceed the 10-minute limit.

## What I tried, in order, and how each problem was diagnosed

1. **Baseline.** I compiled the original (it ends with a `READ`, so I ran it with
   stdin from /dev/null). It converges in under a second.

2. **First deferred-correction version.** This added central differences in the PHI equation,
   the C_0/E_0 source terms, the two-level loop and a RESULT printout. While reading the
   code to map the coefficients, I found a **bug in the original**: `SOR_OMEGA` reads
   `OMEGA(I+1,J,2)` at I = NR. Slot 2 is only refreshed for rows 2:NR, so the wall
   vorticity from Thom's formula was never seen by the interior equation (the wall was
   effectively ω = 0). I fixed this by copying the wall row into slot 2 before the sweep.
   I confirmed the bug's effect later: re-imposing ω_wall = 0 gives D=96 phi_M = 1.70
   instead of about 1.0.

3. **Divergence after the fix (D=96 blew up).** A per-outer-iteration trace (max|PHI|,
   max|W|, max|OMEGA|, sweep counts) showed omega growing without bound. Once the wall
   vorticity was actually coupled, this was the classic Thom-BC instability. Damping the
   wall vorticity fixed D=96.

4. **NaN reported as "converged".** At D=500, W came out as NaN while the SOR reported
   convergence. The SOR tests `ABS(diff) > EPS` are false for NaN, so a diverging
   over-relaxed sweep (ρ = 1.5 on a convection-dominated operator) was accepted. I
   rewrote the tests as `.NOT. (ABS(diff) <= EPS)`, so the existing ρ-reduction retry
   kicks in. I also lowered ρ for W and OMEGA to 1.2 and added a NaN/size check on the
   outer iterate. The original `W_RETRY` loop could also loop forever once the
   ρ-reductions ran out. Now it exits and the case is marked FAILED.

5. **A run that would not finish.** The first full run with continuation took over
   10 minutes; I stopped watching it and timed the cases one at a time. I couldn't kill
   it, because the sandbox does not allow ps, pkill or killall. Note: that orphaned
   process (`./s upwind` in `work/`) may still be running; it is bounded by MAXOUT and
   ends eventually. Since then every run has a built-in wall-clock limit, and I added
   SOR sweep counters and a verbose trace option.

6. **Period-2 oscillation at D=300.** The trace showed phi alternating between 0.7
   and 9.5. I diagnosed under-damped outer iteration (Schubert's XI = 0.1 puts 90% weight
   on the new iterate) and fixed it with XI(PHI) = XI(OMEGA) = 0.5.

7. **Limit cycle at D ≥ 1250.** The trace showed a period-about-9 oscillation of about
   0.3% that never decays. I added environment-variable overrides for the XI and ρ
   factors and scanned them, running several time-limited jobs in parallel. Heavier
   damping of the wall vorticity made it worse. Lighter wall damping (XI_wall = 0.2–0.3)
   combined with heavy damping of interior omega (0.9) removed the cycle all the way to
   D=5000.

8. **Systematic 2.5% offset from C&D.** With item 7 working, deferred correction
   converged at every D, but phi_M was about 2.5–3.6% high and w_M 1.5–2% low, already
   at D=96. At D=96 convection is weak, so the cause had to be the base discretization
   and not the correction. I tested wall-BC variants:
   - Schubert's `PHI(NR) = PHI(NR−1)/4` with Thom: 1.0212 at D=96, about 2.6% high.
   - Poisson equation also at r = 1−h, PHI = 0 at the wall, Thom ω_w = −2PHI(NR)/h²:
     0.9943 / 23.344 at D=96 and 9.3059 / 140.591 at D=1000. This matches C&D.
   - The same with the second-order wall formula −(8φ₁−φ₂)/(2h²): about 0.6–0.9% low.
   - Schubert's 1/4 rule plus the second-order formula: identical to the 1/4 rule plus
     Thom, as expected, since the 1/4 rule makes the two formulas coincide.

   I adopted the second option.

9. **The new BC destabilised D ≥ 1750 again.** Even upwind showed a period-9 cycle. I
   re-ran the XI scan with this BC, and (0.5, 0.0, 0.2, 0.9) for (PHI, W, wall OMEGA,
   interior OMEGA) converges every case, including D=5000.

10. **Tolerance check.** I tightened the inner and correction tolerances 100× (to 1e-9
    and 1e-7). All reported values were unchanged to the printed digits, so the
    remaining 0.1% differences at D=500 and 605.72 are not convergence error. They come
    from the scheme itself, or from details of C&D's discretization I can't see. I
    also changed π from Schubert's 3.14159255 to `ACOS(-1)`.

## Compile/run count

About 17 compilations and about 45 solver runs. The runs include two parameter scans of 8
and 4 parallel jobs, verbose diagnostic runs, the tight-tolerance check and the final run.

## Files

- `solver.f90`: the final solver. Diagnostic options: `./solver upwind` switches the
  correction off; a 2nd argument sets the time limit in seconds; a 3rd argument turns
  on per-iteration tracing.
- `solver.out`: output of the final run.
- `work/`: scratch copies, logs and scans.
