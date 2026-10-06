
## Available tools from earlier work

`adsd/` contains **diagnostic probes** and **retained solver skills** from
earlier work on iterative solvers. Read `adsd/README.md` first.

- Probes: write a per-outer-iteration trace and run
  `python -m adsd.probes trace.csv`. It reports *why* an iteration is not
  converging (dominant eigenvalue of the outer map, oscillation period,
  false convergence, masked NaN, collapse) and names the skill that
  addresses it.
- Skills: `adsd/skills/*.md`, with Fortran in `adsd/skills/fortran/`.

Diagnose before you change things. When something does not converge, trace
it, run the probes, and apply the indicated skill.
