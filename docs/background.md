# Background: AI-Assisted Revival of Dean Flow Code

## Paper

**"Application of artificial intelligence to revive numerical studies of fluid motion in a curved pipe"**
Nils Tångefjord Basse, RISE Research Institutes of Sweden.
*Discover Mechanical Engineering* 5:21 (2026).
DOI: [10.1007/s44245-026-00188-w](https://doi.org/10.1007/s44245-026-00188-w)

Published 17 February 2026. Open Access (CC BY 4.0).

## What it's about

The paper revives a ~600-line FORTRAN 66 code from a 1972 University of Wisconsin
technical report by Greenspan & Schubert [4] that numerically solves the **Dean equations**
for laminar flow in slightly curved pipes. The Dean number D = 4Re*sqrt(2a/L) is the
governing parameter, covering D = 10 to 5000.

## The physics

Three coupled PDEs are solved on a polar cross-section grid (r, alpha) using finite
differences and successive over-relaxation (SOR):

- **phi** - stream function for secondary flow (central differencing, 2nd order)
- **w** - streamwise (axial) velocity (upwind differencing, 1st order)
- **Omega** = -nabla^2(phi) - streamwise vorticity (upwind differencing, 1st order)

### Dean equations

```
nabla_1^2 w + D = (1/r)(dphi/dalpha * dw/dr - dphi/dr * dw/dalpha)

-nabla_1^4 phi = (1/r)(dphi/dr * d/dalpha - dphi/dalpha * d/dr) nabla_1^2 phi
                 + w (dw/dr sin(alpha) + dw/dalpha cos(alpha)/r)
```

where nabla_1^2 = d^2/dr^2 + (1/r) d/dr + (1/r^2) d^2/dalpha^2

### Key physical phenomena

As D increases:
- The streamwise velocity peak shifts outward (toward the outside of the bend)
- Dean vortices (secondary flow) intensify
- The flow blockage effect grows (flux ratio drops relative to straight pipe)
- phi is antisymmetric and w is symmetric about the horizontal plane

### Dean number

D = 4 Re sqrt(2a/L), where:
- Re = bulk Reynolds number
- a = pipe radius
- L = radius of curvature

Valid for the approximation a/L << 1 (interpreted as a/L <= 0.01).
The upper D = 5000 corresponds to the critical Re for turbulence transition at L/a = 31.9.

## The code revival process

### Stage 1: Digitization
- OCR of a poor-quality scanned 1972 technical report [4]
- Amazon Textract achieved ~80% accuracy (best tool found)
- Python tools (EasyOCR, PyTesseract) performed poorly (~50%)
- Two online converters (PDF.ai, MaxAI.me) also ~50%
- ~10% required human correction
- Final approach: AWS Textract + online converters + human correction

### Stage 2: Minimal modern Fortran (Appendix B)
- FORTRAN 77-compatible with some Fortran 90 features
- Key changes:
  - Hollerith strings replaced (via ChatGPT-4)
  - Punch card I/O replaced with file I/O
  - IF/ELSE CASE structure to loop over all 7 Dean numbers
  - MAXSOR increased from 250 to 2500, MAXOUT from 60 to 600
  - SOR over-relaxation factors modified for D=250, 2000, 5000
- Platform: Windows 11, Visual Studio, Intel Fortran Compiler (ifx)

### Stage 3: Complete modern Fortran (Appendix C, .f90)
Done in 24 incremental steps using GitHub Copilot (ChatGPT-4.1).
Major improvements:
1. Free-form source (.f90), `!` comments, `&` continuations
2. `IMPLICIT NONE`
3. Modern DO loops
4. All `GO TO` eliminated
5. `SELECT CASE` for D-value loop
6. Modules: `KIND_MOD`, `ERROR_MOD`, `OUTPUT_MOD`, `SOR_MOD`
7. Separate SOR counters: `ISOR_PHI`, `ISOR_W`, `ISOR_OMEGA`
8. Named DO loops: `OUTER_ITER`, `PHI_SOR`, `W_SOR`, `W_RETRY`, `OMEGA_SOR`, `OMEGA_RETRY`
9. `AMIN1`/`AMAX1` replaced with `MIN`/`MAX`
10. `NEWUNIT` for file I/O
11. Double precision via `SELECTED_REAL_KIND(15, 307)` and `_dp` suffix
12. `SYSTEM_CLOCK` timing
13. `LOGICAL :: FAILED` for convergence tracking
14. Array syntax for initialization

## Key results

### Grid resolutions
- **Original**: NR=10, NA=18 (delta_r = 0.1, delta_alpha = pi/18)
- **Updated**: NR=20, NA=36 (doubled in both directions)
- CPU time scales roughly linearly with grid size

### Comparison with literature
- Flow structure (phi, w contour plots) matches Greenspan 1973 [5] well
- **But**: phi_max, w_max, and flux ratio deviate substantially from the more
  accurate Collins & Dennis 1975 [6] results, even at doubled resolution
- **Reason**: The upwind scheme for w and Omega is only 1st order accurate,
  while Collins & Dennis use central differencing (2nd order) + correction terms
- **However**: Position of w_max vs D matches Collins & Dennis well at the
  updated resolution, because phi (which determines the flow structure) uses
  2nd-order central differencing in both approaches
- Further grid refinement (beyond doubled) showed no appreciable change,
  confirming the discrepancy is due to scheme accuracy, not resolution

### Runtime
- ~5 seconds for all 7 D values on modern hardware
- Original (1973): "no case required more than three minutes of computing time"

### Dean number cases solved

| ctr | D    | EPS(1)  | EPS(2)  | EPS(3)  | RHO(1) | RHO(2) | RHO(3) |
|-----|------|---------|---------|---------|--------|--------|--------|
| 1   | 10   | 1.0E-5  | 1.0E-3  | 1.0E-4  | 1.5    | 1.8    | 1.5    |
| 2   | 100  | 2.0E-4  | 5.0E-3  | 5.0E-3  | 1.5    | 1.7    | 1.5    |
| 3   | 250  | 2.0E-3  | 2.0E-2  | 4.0E-2  | 1.5    | 1.5    | 1.5    |
| 4   | 500  | 4.0E-3  | 4.0E-2  | 8.0E-2  | 1.5    | 1.5    | 1.5    |
| 5   | 1000 | 5.0E-3  | 5.0E-2  | 17.0E-2 | 1.5    | 1.5    | 1.5    |
| 6   | 2000 | 7.0E-3  | 8.0E-2  | 3.0E-1  | 1.2    | 1.2    | 1.04   |
| 7   | 5000 | 1.0E-2  | 15.0E-2 | 6.0E-1  | 1.2    | 1.2    | 1.04   |

Note: For D=2000 and D=5000, RHO values are multiplied by 0.8 compared to nominal
(NTB 2025 modification). XI (smoothing) factors also change for D>=1000.

## Numerical method details

### Variables solved
- **phi(r, alpha)**: stream function for secondary flow
- **w(r, alpha)**: streamwise velocity
- **Omega(r, alpha)** = -nabla_1^2(phi): streamwise vorticity (intermediate variable)

### Differencing schemes used in [4,5]
- **phi**: Central differencing (2nd order accurate)
- **w**: Upwind differencing (1st order accurate)
- **Omega**: Upwind differencing (1st order accurate)

### How Collins & Dennis [6] improved upon this
1. All three equations solved with central differencing (2nd order)
2. Smoothing technique applied to Omega for stability
3. Smaller increments of D used for D > 1000 for convergence
4. Correction terms C_0 and E_0 added to equations for w and Omega

### Solution algorithm
1. For each D value:
   a. Initialize (from zero or previous D solution)
   b. OUTER_ITER loop (nonlinear iteration):
      - Solve phi via SOR (central diff, MAXSOR iterations max)
      - Smooth phi
      - Compute upwind coefficients for w using current phi
      - Solve w via SOR (upwind diff, with retry/relaxation reduction)
      - Smooth w
      - Compute Omega boundary condition from phi
      - Compute source term for Omega from w
      - Solve Omega via SOR (upwind diff, with retry/relaxation reduction)
      - Smooth Omega
      - Check convergence of all three variables
   c. Compute flux ratio QR
   d. Output to file

### Grid layout
- Polar coordinates (r, alpha) on pipe cross-section
- r in [0, 1], alpha in [0, pi] (upper half only; lower half by symmetry)
- phi antisymmetric, w symmetric about alpha = 0 line
- alpha = 0 (360) degrees = outboard, alpha = 180 degrees = inboard
- Boundary conditions: phi = 0, w = 0 on pipe wall (r = 1)

## Supplementary material (code appendices)

| Appendix | File | Format | Grid |
|----------|------|--------|------|
| A | `Schubert_1972_FORTRAN_66.f` | Fixed-form FORTRAN 66 | NR=10, NA=18 |
| B | `Schubert_1972_minimal_modern_Fortran.f` | Fixed-form, mostly F77 | NR=10, NA=18 |
| C | `Schubert_1972_complete_modern_Fortran.f90` | Free-form F90+, modular | NR=20, NA=36 |

## Data availability

- Original data: https://doi.org/10.13140/RG.2.2.35103.01445
- Updated data: https://doi.org/10.13140/RG.2.2.26714.40642
- GNU Octave programs: https://doi.org/10.13140/RG.2.2.30069.84961

## Future work identified by author

To match Collins & Dennis [6] results:
1. Convert numerical schemes for w and Omega from upwind to central difference
2. Include the correction terms C_0 and E_0

The author notes that giving the papers + code to ChatGPT and asking for this
in one go "does not work" - incremental steps with human understanding are required.

## Key references

- [1] Dean WR. Note on the motion of fluid in a curved pipe. Phil Mag. 1927;4:208-23.
- [2] Dean WR. The stream-line motion of fluid in a curved pipe. Phil Mag. 1928;5:673-95.
- [3] McConalogue DJ, Srivastava RS. Motion of fluid in a curved tube. Proc Roy Soc A. 1968;307:37-53.
- [4] Greenspan D, Schubert AB. Secondary flow in a curved tube. Univ. Wisconsin, CS Dept, Tech Report 155. 1972.
- [5] Greenspan D. Secondary flow in a curved tube. J Fluid Mech. 1973;57:167-76.
- [6] Collins WM, Dennis SCR. The steady motion of a viscous fluid in a curved tube. Quart J Mech Appl Math. 1975;28:133-56.
- [7] Berger SA, Talbot L, Yao L-S. Flow in curved pipes. Ann Rev Fluid Mech. 1983;15:461-512.
- [22] Versteeg HK, Malalasekera W. An introduction to computational fluid dynamics. 2nd ed. 2007.
- [24] Canton J, Orlu R, Schlatter P. Characterisation of the steady, laminar incompressible flow in toroidal pipes. Int J Heat Fluid Flow. 2017;66:95-107.
