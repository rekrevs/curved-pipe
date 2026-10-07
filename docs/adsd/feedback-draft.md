# Draft feedback to Chen & Yin (ADSD, arXiv:2610.03872): NOT POSTED

This is a draft for the repository owner to edit and send, or not. Nothing
here has been posted anywhere. Numbers refer to `docs/adsd/*.md` in this
repository.

## Short version (LinkedIn comment, ~150 words)

> Very interesting work. Here is a data point from a problem class outside your
> four domains. We recently reconstructed Collins & Dennis (1975)
> second-order Dean-flow results in a curved pipe with AI assistance. The
> problem is a coupled, nonlinear outer fixed-point iteration (stream function,
> axial velocity, vorticity) with Fox deferred correction up to Dean number
> 5000. In effect it was a manual ADSD run.
>
> Re-doing it your way taught us two things.
>
> 1. **Executable diagnosis caught a wrong retained explanation.** Spectral
>    probes on per-iteration traces showed that our explanation of *why* the
>    key stabiliser worked was wrong: the mode was a complex pair crossing
>    |λ| = 1, not λ = −1. The fix was right; the retained story would have
>    misled the next attempt.
> 2. **There was a ceiling effect.** In a small pilot, fresh agents with and
>    without our probe/skill library both matched the published table to
>    0.16% in about 55 minutes. The library changed the *route*, not the
>    outcome: an eigenvalue-guided structural fix gave a solver that converges
>    without hand-tuned damping constants, and is 11× faster.
>
> Happy to share details.

## Longer note (e-mail or comment thread)

**Setting.** Dean flow in a curved pipe, Collins & Dennis (1975). Three
coupled fields on a polar grid (stream function φ, axial velocity w,
vorticity Ω), SOR inner solves, an outer fixed-point iteration, and Fox
deferred correction to reach central-difference accuracy on top of a stable
upwind solver. Dean numbers run up to 5000. The starting point is a 1972
upwind code that Basse (2026) revived. Unlike your benchmarks, the difficulty
is mostly in the *coupled outer iteration*, not in a single linear solve or
a stiff integrator.

**1. Diagnosis validation matters even when the fix works.**
- Our February reconstruction had added 2-cycle averaging,
  x ← (x + T(x))/2, with the recorded rationale "the outer map has an
  eigenvalue near −1".
- Once we wrote probes that estimate the dominant eigenvalue of the outer map
  from per-iteration traces (a vector Prony fit on successive differences,
  with an amplitude fallback for nonlinear limit cycles), and validated them
  on 19 known-answer checks including held-out runs, they showed:
  - coarse grid: a complex pair near ±45° that crosses |λ| = 1 at D ≈ 1400
    and collapses the solution to zero;
  - fine grid: an exact period-3 cycle (λ = e^{2πi/3});
  - no period-2 mode anywhere.
- Averaging works because (1+λ)/2 contracts any eigenvalue near the unit
  circle except near +1. In your terms, the retained skill was correct but
  its claim dossier was not. Your held-out hypothesis validation (≥ 90%) is
  exactly the step we had skipped.

**2. Retain probes, not only fixes.**
- One bug class was fixed twice in our history: a convergence test on a
  *relaxed* increment, which accepts raw updates 1/(1−ξ) times larger than
  intended.
- The first fix was recorded as a fix and not as a check, so it recurred
  in a different loop.

**3. Pilot (N = 1 per arm, so suggestive only).**
- Two fresh headless agents (same model, same budget, isolated from the
  project's notes) started from the 1972 upwind code with the C&D formulae
  and the target table. Arm B also had our probe/skill library.
- Both reached 7/7 Dean numbers: ≤ 0.16% from C&D on the same grid, with
  identical values to every printed digit, in about 55 min and USD 3–4 each.
- The routes differed:
  - Arm A tuned per-field relaxation by parallel parameter scans.
  - Arm B reasoned from measured eigenvalues. For example, it set the wall
    relaxation from ξ = λ/(λ−1) with λ ≈ −9.3. It then made a structural
    change the library did not contain: nonlinear Gauss–Seidel, one sweep
    per field per outer iteration. That contracted without averaging or
    Anderson, and its solver runs 11× faster.
- Arm B also exposed two probe defects. Magnitude-only observables (max|φ|)
  hide the sign of an alternating mode, so λ ≈ −9.3 was read as +2.1. We
  fixed both and retained the new skill. That is your diagnose → discover →
  retain loop, closed by the agent's own feedback.
- With these hints the task sits at the ceiling for a 2026 frontier model. A
  sharper test needs fewer hints or a transfer task.

**Possibly useful to you:**
- **A benchmark family.** Coupled nonlinear outer iterations (vorticity–
  stream-function CFD with strongly amplifying boundary coupling, deferred
  correction) stress diagnosis differently from your four domains. The
  failure modes are spectral properties of the *outer map*, and observables
  are often magnitudes.
- **A probe pitfall.** Diagnostics computed on norms or maxima can invert
  the sign of the diagnosed mode.

Code, traces and the full write-up are public: https://github.com/rekrevs/curved-pipe (branch `adsd`, `docs/adsd/`).
