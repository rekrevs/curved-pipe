# ADSD on a 1975 CFD solver: retrospective, probes, pilot

In October 2026 Wotao Yin and Peter Chen posted *Training Numerical Intelligence
via Auto-Diagnosis and Skill Discovery* (ADSD, arXiv:2610.03872). An agent
that improves a numerical solver should first **diagnose** why it performs
poorly, use the diagnosis to **discover** a suitable method, **implement** it,
and **retain** it as a reusable skill. Their benchmarks are power flow, AC-OPF,
stiff ODEs and heterogeneous diffusion PDEs.

This repository holds a natural test case they do not cover. It is a
**coupled, nonlinear outer fixed-point iteration** (Dean flow in a curved
pipe: stream function, axial velocity, vorticity) that had to be pushed from
first-order upwind to second-order accuracy with Fox's deferred correction
(Collins & Dennis 1975), up to Dean number 5000. That was done in February 2026
by a human orchestrating Claude Code and ChatGPT, and is documented task by
task in `wotan/dev-log/`.

## What we did (T-0010..T-0013)

| Task | Output | Read |
|------|--------|------|
| T-0010 | The reconstruction re-read as a manual ADSD run: 6 failure episodes, diagnoses, falsified remedies, gaps vs ADSD | [`retrospective.md`](retrospective.md) |
| T-0011 | `adsd/`: solver-agnostic diagnostic probes on iteration traces + 6 retained skills (with standalone Fortran Anderson module); validated on 19 real-trace checks incl. held-out grid (c) | [`../../adsd/README.md`](../../adsd/README.md), [`probe-validation.md`](probe-validation.md) |
| T-0012 | Pilot: two fresh agents start from the 1972 upwind solver, without vs with the library, scored against C&D | [`pilot.md`](pilot.md) |
| T-0013 | This summary + draft feedback to the authors | [`feedback-draft.md`](feedback-draft.md) |

## Findings so far

1. **We had done ADSD by hand, but skipped the "validate the diagnosis" step.**
   Diagnoses were argued in prose for an external advisor, never measured.
   The relaxed-convergence-test bug was fixed twice (T-0001, then again before
   T-0005) because it was retained as a *fix*, not as a *probe*.
2. **Measuring the diagnoses corrected the project's own retained knowledge.**
   The project notes said 2-cycle averaging works because the outer map has
   an eigenvalue near −1. Executable spectral probes show something else:
   - On grid (b), the instability is a complex pair near ±45° that crosses
     \|λ\| = 1 at D ≈ 1400.
   - On grid (c), it is an exact period-3 cycle.
   - Averaging fixes both because (1+λ)/2 contracts any eigenvalue near the
     unit circle except near +1. The fix was right; the explanation was
     wrong; and the wrong explanation would have mis-steered the next problem.
3. **Thresholds do not transfer between grids; mechanisms do.** Grid (b) to
   grid (c) needed six parameters re-tuned. The probe-plus-skill pair instead
   decides from the trace whether averaging, Anderson or neither applies.
4. **Pilot:** see [`pilot.md`](pilot.md).

## Reuse

```bash
python -m adsd.probes trace.csv          # diagnose an outer-iteration trace
python -m pytest adsd/tests -q           # probe unit tests
python -m adsd.validation.analyze <dir>  # re-run the real-trace validation (after solver_traces)
```
