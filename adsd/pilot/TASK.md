# Task: a second-order accurate Dean-flow solver

## What you have

`Schubert_1972_complete_modern_Fortran.f90` is a working Fortran 90 solver for
steady, fully developed laminar flow in a curved pipe (the Dean problem). It
uses a polar grid (r, alpha), NR = 20 and NA = 36, so h = 0.05 and
k = pi/36, symmetric about alpha = 0, pi. Three coupled fields are solved:

- PHI, the secondary-flow stream function (Poisson equation driven by OMEGA)
- W, the axial velocity (convection-diffusion, convection by the secondary flow)
- OMEGA, the axial vorticity (convection-diffusion, source from W)

Each field has an SOR inner solve inside an outer fixed-point iteration, for a
list of Dean numbers D. The convective terms are **upwind** differenced, which
is stable but only first-order accurate.

## What Collins & Dennis (1975) did

Collins & Dennis (Q. J. Mech. Appl. Math. 28(2), 133ff., 1975) reached
**second-order (central-difference) accuracy on the same kind of grid** with
Fox's deferred correction. They kept the stable upwind SOR solver and added
correction terms as frozen source terms:

    C_0(i,j) = -(1/2r) [ |DELTA| (W_E + W_W - 2 W_0) + |GAMMA| (W_N + W_S - 2 W_0) ]     (W equation)
    E_0(i,j) = -(1/2r) [ |DELTA| (Om_E + Om_W - 2 Om_0) + |GAMMA| (Om_N + Om_S - 2 Om_0) ] (Omega equation)

DELTA and GAMMA are the convective coefficients of the r- and alpha-direction
differences. Upwind plus correction equals central differencing. The
iteration has two levels:

1. With C_0 and E_0 frozen, iterate the coupled fields to convergence.
2. Compute new C_0, E_0 from the converged fields, update them with smoothing,
   `C_0 <- omega1 * C_0_new + (1 - omega1) * C_0`, and repeat until the
   corrections converge.

The stream-function equation has no convective term. Use central
differences there.

You must work out how these formulae map onto this code's coefficients and
normalisation.

## Goal

Write `solver.f90`, a modified copy of the Schubert solver, that reproduces
Collins & Dennis's values on this grid for

    D = 96, 500, 605.72, 1000, 2000, 3500, 5000

with phi_M = max |PHI| and w_M = max |W| over the whole grid:

| D | phi_M (C&D) | w_M (C&D) | grid |
|------|-------|--------|------|
| 96 | 0.995 | 23.34 | this grid (h = 0.05) |
| 500 | 6.166 | 83.50 | this grid |
| 605.72 | 6.972 | 96.24 | this grid |
| 1000 | 9.308 | 140.6 | this grid |
| 2000 | 13.38 | 234.9 | this grid |
| 3500 | 17.13 | 351.4 | C&D's finer grid (h = 0.025) only |
| 5000 | 19.97 | 449.3 | C&D's finer grid (h = 0.025) only |

For D = 3500 and 5000 only finer-grid reference values exist. On this grid,
aim for a converged, non-trivial solution with phi_M within a few percent.

## Required output

`gfortran -O2 -o solver solver.f90 && ./solver` must finish in under 10
minutes and print, for every D above, one line of the form

    RESULT D=<D> PHI_M=<phi_M> W_M=<w_M> STATUS=<CONVERGED|FAILED>

## Rules

- Work only inside this directory. Do not read or search any other
  directory on this machine, and do not use the web.
- When you are done, or decide to stop, write `REPORT.md` with:
  - your final results table
  - what you tried, in order, including what failed
  - how you diagnosed each problem
  - roughly how many times you compiled and ran the solver
