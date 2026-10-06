# ADSD Retrospective: the C&D (1975) reconstruction as a manual ADSD run

Chen & Yin, *Training Numerical Intelligence via Auto-Diagnosis and Skill
Discovery* (arXiv:2610.03872, 2026) describe **ADSD**, a loop for agents that
improve numerical solvers:

1. **Diagnose**: run executable probes on the failing solver (residual
   histories, conditioning, stiffness, iteration counts). Form hypotheses about
   *why* it fails, and keep only hypotheses validated on a held-out pool
   (they use a validation rate of at least 90%).
2. **Discover**: let the diagnosis steer the search for a method in the
   literature, keeping methods whose assumptions match the solver.
3. **Implement** the method in the solver.
4. **Retain**: store the improvement as a reusable *skill*, made of executable
   code, usage instructions, and a dossier of evidence.

This document re-reads the reconstruction of Collins & Dennis (1975) on top of
the Schubert (1972) solver (Step 0, T-0001..T-0005, 18–20 Feb 2026) through
that lens. Sources: `wotan/dev-log/T-0001..T-0005.md`, `docs/attempts.md`,
`docs/almost-there.md`, `docs/still-struggling.md`, `the-making-of.md`,
`the-making-of-uncut.md`, git history.

## Summary table

| # | Symptom | Diagnosis (and how it was established) | Method source | Remedy | Retained as | Probe for T-0011 | Skill for T-0011 |
|---|---------|------------------------------------------|---------------|--------|-------------|------------------|------------------|
| E0 | Corrected solution not 2nd-order accurate | Discretisation slips in the PHI stencil and boundaries. Found by code review against C&D equations | ChatGPT review of `problem_description_for_chatgpt.md` | Central PHI coefficients, Dirichlet enforcement, removal of early-stop heuristic | `CHECK_CENTRAL_RESIDUALS`, `verify_fox.py` | Target-scheme residual check | Deferred-correction consistency check |
| E1 | Wrong solution near wall | Wall vorticity in SOR "old" slice never updated (stuck at 0). Established by code inspection | Own analysis | Propagate wall BC to slice 2 (T-0002 for remaining frames) | Code + attempts.md | Boundary freshness check | — (one-off bug) |
| E2 | D≥2000 never converges; under-relaxed runs "converge" to near-zero | (a) Loop gain PHI→Ω_wall ∝ 2/h² = 800 exceeds Picard stability. (b) Convergence test measured the *relaxed* increment, so heavy damping faked convergence. (a) was argued, (b) was shown by arithmetic | ChatGPT plan (Steps A–C) | Test `XIC*EPS` (unrelaxed update); `RES_WALL` residual diagnostic; stabilised XI table | T-0001 log, CLAUDE.md gotcha #3 | False-convergence check | Unrelaxed convergence test |
| E3 | High-D cases start badly; corrections relearned from 0 | Small ω₁ means correction warm-start matters. Later: D-stepping started from a *corrected* solution with *zero* corrections (inconsistent state) → crash | ChatGPT (Step E); own debugging | Carry C₀/E₀ between D cases; hand off *uncorrected* solution | T-0003/T-0004 logs, CLAUDE.md gotcha #2 | — | Consistent continuation handoff |
| E4 | Persistent oscillation at D≥2000 (grid b), D≥500 (grid c) | Period-2 limit cycle (eigenvalue ≈ −1), period-3 on grid c. Established from DIAG traces (maxPHI alternating 7↔23) | `attempts.md` "ideas not yet tried"; ChatGPT plan | **2-cycle averaging** `x ← (x + T(x))/2`, incl. wall BC | T-0004 log, CLAUDE.md | Oscillation period + dominant eigenvalue | 2-cycle averaging |
| E5 | D=5000: Fox corrections destabilise outer iteration (NaN or collapse to 0) after ~8% of correction applied | Narrow basin of attraction for Picard; NaN invisible to `MAX` reductions; correction convergence metric again measured the *damped* update | ChatGPT multi-stage plan citing Anderson/Pollock et al. (2019) | **Anderson acceleration** (Type-I, m=4, β=0.5, \|α\|>10 restart); `ieee_is_finite` guards; undamped correction residual | T-0005 log, CLAUDE.md gotchas #1, #4 | NaN-visibility check; false-convergence check (again) | Anderson acceleration; NaN-safe reductions |

## Episodes in more detail

### E0: Fox correction implementation (Step 0, commit `7a0279f`)

- **Symptom.** The corrected solver did not reproduce C&D values even for low D.
- **Diagnosis.** A code review against C&D eqs. 13/17 found an asymmetric
  stencil for (1/r)∂φ/∂r, a special-cased I=NR row, missing Dirichlet
  enforcement and an early-stop heuristic (`docs/attempts.md` Round 1).
- **Probe that came out of it.** `CHECK_CENTRAL_RESIDUALS` computes residuals
  of the *target* central-difference equations. If deferred correction has
  converged, those residuals must vanish. This was already a genuine executable
  diagnostic in the ADSD sense. `verify_fox.py` checks the algebra
  "upwind + C₀ = central" separately.
- **Retained lesson.** For deferred correction, measure the residual of the
  scheme you are *aiming at*, not the one you iterate with.

### E1: Stale wall boundary in SOR (attempts.md Round 2, T-0002)

- **Symptom.** Wrong near-wall solution.
- **Diagnosis.** `OMEGA(NRP1,:,2)`, the wall row read in the Jacobi direction,
  was never written and stayed at zero.
- **Side effect.** The correct fix *revealed* the coupling instability of E2.
  A bug had been providing accidental damping. That pattern is worth
  remembering, but it is not a reusable remedy.

### E2: Limit cycle vs. false convergence (T-0001, commit `271219f`)

- **Symptom.** At D≥2000 every XI(3) choice failed. Low damping oscillated.
  High damping "converged" to φ_M≈0.04 (`docs/attempts.md` table).
- **Diagnosis (b) was the decisive one.** `SMOOTH` tested
  `|old − relaxed| = XIC·|old − raw|` against EPS, so XI=0.9 made the test 10×
  looser. Heavy damping did not stabilise the iteration. It switched the
  convergence test off.
- **Diagnosis (a)** (gain 2/h² = 800) was argued, not measured. No
  spectral estimate was ever computed.
- **Remedy.** Test `XIC·EPS` and add the `RES_WALL` residual diagnostic.
  The XI changes did not by themselves converge D≥2000; they only stopped
  the false convergence.

### E3: Continuation and correction warm start (T-0003 `6d19af9`, T-0004)

- **Carrying C₀/E₀** helped D=2000 a lot (φ_M 3.10 → 15.44), made D=3500
  worse (12.59 → 49.33) and left D=5000 unchanged. The hypothesis was only
  partially supported, but the change was kept.
- **Uncorrected handoff.** D=5000 D-stepping crashed because it started
  from D=3500's *corrected* fields with corrections reset to zero. Diagnosis:
  the state was inconsistent with the operator. Remedy: save the uncorrected
  fields for the handoff.

### E4: The period-2 oscillation (T-0004, commit `4ed46cd`)

- **Symptom.** maxPHI alternated roughly between 7 and 23 at D=2000. On grid
  (c), the oscillation had period 3 and appeared already from D≥500.
- **Diagnosis.** The outer fixed-point map has a dominant eigenvalue near −1
  (period 2), or a complex pair at ±120° (period 3). This was read off the
  DIAG traces by eye. It was never quantified.
- **Alternatives tried and rejected (falsified or traded off):**
  - Parabolic wall formula `φ(NR) ≈ 0.25 φ(NR−1)`, taken from Schubert's
    code. It cuts the loop gain from 800 to about 200 and stabilises
    D-stepping, but costs about 3% in φ_M at D≤1000. Rejected.
  - Parabolic formula only during D-stepping: D=3500 crashed because the
    stencils were incompatible.
  - C&D iteration order W→Ω→φ (C&D §4, wall BC lags one iteration). On its
    own this "didn't help — same crash at D≈1430" (`the-making-of-uncut.md`
    l.1805). It was still kept, and CLAUDE.md now says that changing the
    order makes the corrections diverge. **That claim has not been
    re-tested since the stabilisers were added.**
  - XI(2)=0.5 for W made D-stepping collapse to zero.
- **Remedy.** 2-cycle averaging. It maps eigenvalue −1 to 0 and the ±120°
  pair to modulus 0.5.
- **Transfer to grid (c) was not free.** The averaging threshold moved from
  D≥2000 to D≥250, and MAXSOR, D_STEP, STEP_ITERS and RHO_W all had to be
  re-tuned. Diagnosis on the coarse grid did not carry its thresholds over.

### E5: The D=5000 correction wall (T-0005, commit `72e7773`)

- **Symptom.** Applying more than about 8% of the Fox correction (w_M stuck at
  434.0 against the 449.3 target) produced NaN or a collapse to the trivial
  solution.
- **Diagnoses:**
  - The basin of attraction of Picard iteration is narrow.
  - `MAX(a, NaN) = a` in gfortran made NaN invisible, so a diverged run
    "converged" with φ_M = w_M = 0.
  - The correction convergence metric used the *damped* update ω₁·|ΔC₀|, so
    the true residual was 20× larger. This is the **same bug class as E2**.
- **Falsified remedies (`docs/still-struggling.md`):**
  - v1: wall-Ω criterion
  - v7: heavy under-relaxation + Gauss-Seidel (diverged)
  - v10/v11/v11b: restore, minimum outer iterations, restart-on-collapse
  - v12, the best Picard result, still had a 3.4% gap.
- **Discovery.** Anderson acceleration was explicitly motivated from the
  literature (Pollock et al. 2019 for Navier–Stokes Picard at high Re, cited
  in `docs/still-struggling.md`) with the argument "can converge to fixed
  points Picard cannot".
- **Result.** w_M = 449.37 against C&D's 449.3, with all 692 correction
  iterations stable.

## How our process differed from ADSD

| ADSD step | What we did | Gap |
|-----------|-------------|-----|
| Executable diagnosis | Mostly *argued* diagnoses written in long prose documents (`attempts.md`, `almost-there.md`, `still-struggling.md`) for an external advisor. Executable exceptions: `CHECK_CENTRAL_RESIDUALS`, `RES_WALL`, NaN checks | No spectral estimate of the outer map was ever computed. The oscillation period was read by eye |
| Hypothesis validation (≥90% on a held-out pool) | Validated by outcome on the D table, one case at a time | Several retained claims were never independently validated, e.g. the necessity of the iteration order and the "gain 800" story |
| Diagnosis-guided discovery | Human routes the document to ChatGPT, which returns a staged plan | Worked well, but each round took hours and needed a human in the loop |
| Retain as skills | Dev-logs, CLAUDE.md "gotchas", memory file: prose, not executable | The relaxed-update bug recurred (E2, then E5): the lesson was retained as a *specific fix*, not as a *general probe* |
| Transfer | Grid (b) → grid (c) needed re-tuning of 6+ parameters | Thresholds did not transfer, while mechanisms (averaging, Anderson) did |

**Cost of the manual run.** 2.5 days, 101 user inputs over 11 sessions,
three escalation documents, at least 12 named failed variants for D=5000
alone.

## What this implies for T-0011 (library) and T-0012 (pilot)

**Probes worth making executable:**
1. **Oscillation period and dominant eigenvalue of the outer map.** This would
   have quantified E4 directly and told us that averaging, rather than
   damping, was the remedy.
2. **False-convergence check.** It would have caught E2(b) and E5's damped
   metric at once.
3. **Non-finite / masked-NaN check** (E5).
4. **Target-scheme residual** for deferred correction (E0). This one already
   exists in the solver.

**Skills worth retaining**, each with its diagnosis trigger:

| Skill | Trigger |
|-------|---------|
| Unrelaxed convergence test | — |
| 2-cycle averaging | dominant λ ≈ −1, or periodic oscillation |
| Anderson acceleration with safeguards | slow or unstable Picard, narrow basin, corrections destabilise |
| Consistent continuation handoff | parameter stepping crashes at the start of a new case |
| NaN-safe reductions | — |
| Deferred-correction consistency check | — |

**Pilot design implication.** The interesting question is whether a fresh
agent with probes and skills avoids the E2→E5 detours, i.e. reaches the D≤2000
table and gets close at high D faster and with fewer falsified variants. It is
not whether the agent can rediscover Anderson acceleration.
