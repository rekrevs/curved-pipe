# ADSD pilot: fresh agent, without vs with the library (T-0012)

## Setup

| | Arm A (baseline) | Arm B (ADSD library) |
|-|------------------|----------------------|
| Start | `Schubert_1972_complete_modern_Fortran.f90` (upwind) | same |
| Task | [`adsd/pilot/TASK.md`](../../adsd/pilot/TASK.md): C&D formulae, target table, required output | same + [`TASK_ADSD_ADDENDUM.md`](../../adsd/pilot/TASK_ADSD_ADDENDUM.md) |
| Extra | — | `adsd/` (probes, 6 skills, Fortran Anderson module, tests); no validation code or project docs |
| Agent | headless `claude -p`, model `claude-opus-5-5`, started outside the repo | same |
| Isolation | `--restricted` (file tools confined to workspace, user settings ignored), `--strict-mcp-config`, no web, outer OS sandbox (writes only to scratch, network only to the API) | same |
| Budget | 4 h wall clock, USD 40 | same |

The harness is in `adsd/pilot/pilot.py` (setup / run / score / audit). It was
committed (`e1394e8`) before the runs. Both arms ran in parallel on
2026-10-06, 21:32–22:27 CEST.

**Scoring was independent.** We compiled and ran each arm's final
`solver.f90` ourselves and parsed the `RESULT` lines.

- **D ≤ 2000:** pass requires φ_M and w_M within 1% of C&D (grid b). Plain
  upwind misses by 1.6–8.6% here, so this criterion separates first-order
  from second-order.
- **D = 3500 and 5000:** pass requires a converged solution with φ_M within
  3% of C&D's finer-grid value.

## Results

| | Arm A | Arm B |
|-|-------|-------|
| **Score** | **7/7** | **7/7** |
| Wall clock to finish | 55.1 min | 54.2 min |
| Cost (reported) | USD 2.72 | USD 3.85 |
| Turns / tool calls | 52 / 51 | 53 / 52 |
| Compiles / executions | 18 / 26 | 20 / 35 |
| Probe runs | — | 15 |
| Final solver run time | 93 s | 8.5 s |
| Access outside workspace | none found | none found |

**Both arms converged to the same discrete solution, digit for digit:**

| D | 96 | 500 | 605.72 | 1000 | 2000 | 3500 | 5000 |
|---|----|-----|--------|------|------|------|------|
| φ_M | 0.9943/0.9944 | 6.1583 | 6.9618/9 | 9.3059 | 13.3691 | 17.4756 | 20.4271 |
| w_M | 23.344 | 83.400 | 96.201 | 140.591 | 234.524 | 347.234 | 443.990 |
| vs C&D | ≤0.07% | ≤0.12% | ≤0.15% | ≤0.02% | ≤0.16% | φ +2.0% | φ +2.3%, w −1.2% (C&D grid c) |

Our own grid (b) solver gives the same values at D = 2000 (13.3721 / 234.53)
and D = 3500 (17.4689 / 347.20) to about 4 digits. At D = 5000 both agents
converge the **full** deferred correction on grid (b), giving w_M = 443.99.
Our solver gives that up and runs D = 5000 uncorrected on grid (b)
(OMEGA1 = 0, w_M = 402.6). Both agents also see the same ~0.12% gap to C&D at
D = 500/605.72 that our solver shows. They each verified that it is not
iteration error, so it is a discretisation detail that differs from C&D's.

## How they got there

Both independently rediscovered most of the February 2026 history.

**Shared by both arms:**
- They had to solve the PHI Poisson equation on the r = 1−h row with PHI = 0
  at the wall and use Thom's wall vorticity. Schubert's `PHI(NR) = PHI(NR−1)/4`
  gives a systematic ~2.5% error.
- This makes the PHI → ω_wall → ω → PHI loop unstable, so the wall vorticity
  must be relaxed.
- They corrected π (Schubert used 3.14159255).
- They continued the uncorrected solution in D.

**Arm A** (no library):
- It found the stale wall slot in `SOR_OMEGA`. This is our episode E1, which
  took us a ChatGPT round in February.
- It found that `ABS(diff) > EPS` is false for NaN, so a diverging sweep
  "converged". This is the E5 bug class.
- It diagnosed by reading per-iteration traces by eye (period 2 at D = 300,
  period ≈ 9 at D ≥ 1250).
- It tuned the per-field relaxation factors XI by **parallel parameter scans**.

**Arm B** (library):
- It diagnosed with the probes. One case gave the remedy quantitatively:
  wall relaxation ξ = λ/(λ−1) ≈ 0.9 for λ ≈ −9.3.
- It applied two-cycle averaging (it found λ ≈ −1 at D ≥ 150 in its own
  block-Picard structure), Anderson, continuation-handoff and NaN guards from
  the skills.
- It ended up **beyond the library**: replacing full per-field solves by
  nonlinear Gauss–Seidel (one SOR sweep per field per outer iteration) made
  every case contract (|λ| ≈ 0.45–0.75) with no averaging or Anderson, and
  cut run time 11×.
- **The probes misled it once.** With only max|field| observables, the sign
  of an alternating mode is lost, so λ ≈ −9.3 was reported as +2.1. The agent
  caught this with a signed test.
- The probe's `empirical_rate` printed ~1e300 on traces that converge
  exactly.

## Interpretation

1. **Ceiling effect.** With the formulae and target table in hand, a 2026
   frontier model solves the whole task in under an hour without help. The
   library did not change success (7/7 vs 7/7) or time-to-solution (55 vs 54
   min), and cost about 40% more tokens, mostly reading and running probes. On
   this task the pilot **cannot show** that retained skills help success.
2. **The library changed the route, not the outcome.**
   - Arm A tuned constants (XI per field) by scanning.
   - Arm B reasoned from measured eigenvalues and ended at a structural
     change of the iteration (nonlinear Gauss–Seidel). That gave a much
     faster solver whose convergence needs no tuned constants.
   - With N = 1 per arm this is suggestive only.
   - **The runtime gap (93 s vs 8.5 s) matters less than it looks.** Both
     are far below the limit, and ours takes about 12 s. The measurement is
     one run each, with different tolerances and continuation schedules. The
     more important difference is that arm B's convergence needs no tuned
     damping constants, while arm A's rests on scanned relaxation factors
     that are unlikely to transfer to other grids or D ranges.
3. **The pilot fed the retain step.** Arm B's run exposed two concrete probe
   defects (sign loss, rate overflow) and produced a new candidate skill
   (nonlinear Gauss–Seidel inner level for stiffly coupled fields).
   This is the loop ADSD describes.
4. **The comparison with February is not like for like.**
   - Then: 2.5 days, 101 human inputs, Claude Code (Opus 4.6) + ChatGPT.
   - Now: 55 min, no human input.
   - Differences: the model generation, and the task text, which was
     written with hindsight. It hands over the C_0/E_0 formulae, the
     two-level structure and the targets. In February those had to be
     extracted from the paper.

## Threats to validity

- **N = 1 per arm**, one model, one task.
- **The library is in-distribution.** It was distilled from this very
  problem, so arm B measures reuse, not transfer.
- **Prior knowledge.** The model may know C&D (1975) and Thom's formula from
  pretraining. This is the same for both arms.
- **Isolation is enforced but not airtight.** Bash could read outside the
  workspace. The audit (all tool inputs scanned for paths outside the
  workspace, repo names and `adsd` in arm A) found nothing.
- Arm A left a possibly orphaned bounded process (its sandbox disallowed
  `ps`/`kill`). It is harmless and terminates via MAXOUT.

## What a sharper test would need

- A task beyond the ceiling: fewer hints (no formulae), grid (c) with the
  10-minute limit, or a *different* solver family (e.g. the turbulent solver
  in this repo, or a non-Dean problem) for **transfer**.
- Several runs per arm.

Archived artefacts are in `docs/adsd/pilot-artifacts/` (reports, final solvers,
scores, audits, compressed transcripts).
