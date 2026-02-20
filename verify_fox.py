"""
Verify the Fox correction C_0 in the Collins & Dennis (1975) curved-pipe solver.

The Fox (deferred) correction method works as follows:
  - The SOR solver uses UPWIND differencing for the W equation (1st order,
    guaranteed diagonal dominance).
  - A correction term C_0 is added as a frozen source so that, at convergence,
    the discrete equation matches CENTRAL differencing (2nd order).

The algebraic identity to verify at every interior point is:

    upwind_residual + C_0 = central_diff_residual

where the "residual" means the left-hand side minus right-hand side of the
respective discrete W equation (both should be zero at convergence, but the
correction bridges the gap between the two schemes).

More precisely, for the W equation the convective operator is:
    L[W] = nabla_1^2 W + D - (1/r)(DELTA * dW/dr_upwind - GAMMA * dW/dalpha_upwind)

The upwind scheme biases the first derivatives using the sign of DELTA and GAMMA.
The central scheme uses symmetric (unbiased) first derivatives.
The Fox correction C_0 is exactly the difference:
    C_0 = -0.5/r * [ |DELTA| * (W_E + W_W - 2*W0) + |GAMMA| * (W_N + W_S - 2*W0) ]

which is derived from the truncation-error difference between upwind and central
discretizations.

References:
  - Collins WM, Dennis SCR (1975), Q. Jl Mech. appl. Math., 28(2), 133-156.
  - Fox L (1947), Proc. Roy. Soc. A, 190, 31-59.
"""

import numpy as np
import sys


def main():
    # ----------------------------------------------------------------
    # 1. Read the converged solution file
    # ----------------------------------------------------------------
    filepath = "/Users/sverker/repos/curved-pipe/cd_file_D500.00.dat"
    print(f"Reading solution file: {filepath}")
    print("=" * 72)

    with open(filepath, "r") as f:
        tokens = f.read().split()

    idx = 0

    def read_int():
        nonlocal idx
        val = int(tokens[idx])
        idx += 1
        return val

    def read_float():
        nonlocal idx
        val = float(tokens[idx])
        idx += 1
        return val

    def read_floats(n):
        nonlocal idx
        vals = [float(tokens[idx + k]) for k in range(n)]
        idx += n
        return np.array(vals)

    NRP1 = read_int()
    NAP1 = read_int()
    NR = NRP1 - 1  # 20
    NA = NAP1 - 1  # 36

    print(f"NRP1 = {NRP1}, NAP1 = {NAP1}")
    print(f"NR   = {NR},   NA   = {NA}")

    XI = read_floats(4)
    RHO = read_floats(3)
    EPS = read_floats(3)
    D = read_float()
    QR = read_float()

    print(f"XI   = {XI}")
    print(f"RHO  = {RHO}")
    print(f"EPS  = {EPS}")
    print(f"D    = {D}")
    print(f"QR   = {QR}")

    # Read PHI, W, OMEGA arrays -- each is (NRP1, NAP1) stored row by row.
    # Fortran writes: DO I = 1, NRP1; WRITE(unit,*) PHI(I,:,3); END DO
    # So each "row" is PHI(I, 1:NAP1) -- we use 0-based storage internally
    # but will use 1-based wrappers for clarity.

    def read_array_2d(nr1, na1):
        """Read a (nr1, na1) array from the token stream."""
        arr = np.zeros((nr1, na1))
        for i in range(nr1):
            for j in range(na1):
                arr[i, j] = read_float()
        return arr

    PHI_raw = read_array_2d(NRP1, NAP1)
    W_raw = read_array_2d(NRP1, NAP1)
    OMEGA_raw = read_array_2d(NRP1, NAP1)

    # Verify we consumed all tokens
    remaining = len(tokens) - idx
    print(f"Tokens remaining after reading: {remaining}")
    assert remaining == 0, f"Expected 0 remaining tokens, got {remaining}"

    # ----------------------------------------------------------------
    # 2. Create 1-based index wrappers
    # ----------------------------------------------------------------
    # In Fortran, arrays are indexed PHI(I,J) with I=1..NRP1, J=1..NAP1.
    # In Python, PHI_raw[i-1, j-1] corresponds to Fortran PHI(I,J).

    def PHI(i, j):
        return PHI_raw[i - 1, j - 1]

    def W(i, j):
        return W_raw[i - 1, j - 1]

    def OMEGA(i, j):
        return OMEGA_raw[i - 1, j - 1]

    # ----------------------------------------------------------------
    # 3. Reconstruct grid parameters (matching Fortran code exactly)
    # ----------------------------------------------------------------
    PI = 3.14159255  # Matching the Fortran code's value
    DR = 1.0 / NR
    DA = PI / NA
    DRH = 0.5 * DR
    DAH = 0.5 * DA
    DRDAM = DR * DA
    DRDA = DR / DA
    DADR = DA / DR
    DDRDAM = D * DRDAM

    print(f"\nGrid parameters:")
    print(f"  DR     = {DR}")
    print(f"  DA     = {DA}")
    print(f"  DRDA   = {DRDA}")
    print(f"  DADR   = {DADR}")
    print(f"  DRDAM  = {DRDAM}")
    print(f"  DDRDAM = {DDRDAM}")

    # Precompute RINV(I) = 1/r(I) and RINV2(I) for I=2..NR
    def RINV(i):
        return 1.0 / ((i - 1) * DR)

    def RINV2(i):
        return RINV(i) ** 2

    def r_val(i):
        return (i - 1) * DR

    # EE(I) = 2*(DADR + DRDA*RINV2(I))  -- base part of denominator
    def EE(i):
        return 2.0 * (DADR + DRDA * RINV2(i))

    # EF(I) = DRDA * RINV2(I)  -- coefficient for angular neighbors
    def EF(i):
        return DRDA * RINV2(i)

    # ----------------------------------------------------------------
    # 4. Compute phi_M and w_M from the solution
    # ----------------------------------------------------------------
    phi_M = np.max(np.abs(PHI_raw))
    w_M = np.max(np.abs(W_raw))
    print(f"\nSolution diagnostics:")
    print(f"  phi_M = {phi_M:.6f}")
    print(f"  w_M   = {w_M:.6f}")

    # ----------------------------------------------------------------
    # 5. Verify Fox correction at multiple test points
    # ----------------------------------------------------------------
    print("\n" + "=" * 72)
    print("FOX CORRECTION VERIFICATION")
    print("=" * 72)
    print()
    print("The identity to verify:  upwind_residual + C_0 = central_diff_residual")
    print("  or equivalently:  C_0 = central_diff_residual - upwind_residual")
    print()

    # We will check multiple interior points
    test_points = [
        (10, 10),  # mid-radius, mid-angle
        (5, 5),    # inner region
        (15, 20),  # outer region
        (10, 18),  # mid-radius, near pi/2
        (3, 30),   # near center, large angle
        (18, 8),   # near wall, small angle
    ]

    max_error = 0.0
    print(f"{'Point (I,J)':>12} | {'DELTA':>12} {'GAMMA':>12} | "
          f"{'Upwind res':>14} {'Central res':>14} {'C_0':>14} | "
          f"{'Error':>14} {'Rel err':>14}")
    print("-" * 130)

    for (II, JJ) in test_points:
        # Validate point is interior: I in [2, NR], J in [2, NA]
        assert 2 <= II <= NR, f"I={II} out of range [2, {NR}]"
        assert 2 <= JJ <= NA, f"J={JJ} out of range [2, {NA}]"

        # ------------------------------------------------------------------
        # Compute DELTA and GAMMA at this point
        # ------------------------------------------------------------------
        DELTA = DA - 0.5 * (PHI(II, JJ + 1) - PHI(II, JJ - 1))
        GAMMA = 0.5 * (PHI(II + 1, JJ) - PHI(II - 1, JJ))

        r = r_val(II)
        rinv = RINV(II)
        rinv2 = RINV2(II)
        ee = EE(II)
        ef = EF(II)

        # Neighbor W values (compass notation: E=I+1, W=I-1, N=J+1, S=J-1)
        W0 = W(II, JJ)
        W_E = W(II + 1, JJ)  # east  (r+dr)
        W_W = W(II - 1, JJ)  # west  (r-dr)
        W_N = W(II, JJ + 1)  # north (alpha+da)
        W_S = W(II, JJ - 1)  # south (alpha-da)

        # ------------------------------------------------------------------
        # A. UPWIND stencil coefficients (from Fortran code)
        #
        # The upwind discretization of the W equation at interior point (I,J):
        #
        #   E(I,J,6)*W0 = E_coeff_E*W_E + E_coeff_N*W_N + E_coeff_W*W_W
        #                + E_coeff_S*W_S + DDRDAM
        #
        # where E(I,J,6) is the sum of all neighbor coefficients (diagonal),
        # and the normalized form has coefficients E(I,J,1..4) = coeff/E(I,J,6).
        #
        # The upwind biases the first derivative based on sign:
        #   DELTA > 0: bias toward E (I+1)
        #   DELTA < 0: bias toward W (I-1)
        #   GAMMA > 0: bias toward N (J+1)
        #   GAMMA < 0: bias toward S (J-1)
        # ------------------------------------------------------------------

        # Unnormalized upwind coefficients (numerators before dividing by denom)
        upw_E_coeff = DADR + rinv * max(DELTA, 0.0)   # E(I,J,1) * denom
        upw_N_coeff = ef + rinv * max(GAMMA, 0.0)     # E(I,J,2) * denom
        upw_W_coeff = DADR - rinv * min(DELTA, 0.0)   # E(I,J,3) * denom  (note: -min = +|neg part|)
        upw_S_coeff = ef - rinv * min(GAMMA, 0.0)     # E(I,J,4) * denom
        upw_denom = ee + rinv * (abs(GAMMA) + abs(DELTA))  # E(I,J,6)

        # Verify coefficient sum equals denominator
        coeff_sum = upw_E_coeff + upw_N_coeff + upw_W_coeff + upw_S_coeff
        assert abs(coeff_sum - upw_denom) < 1e-12, \
            f"Coefficient sum check failed: {coeff_sum} != {upw_denom}"

        # Upwind equation in unnormalized form:
        #   upw_denom * W0 = upw_E*W_E + upw_N*W_N + upw_W*W_W + upw_S*W_S + DDRDAM
        # Residual = RHS - LHS (should be zero for converged solution)
        upw_rhs = (upw_E_coeff * W_E + upw_N_coeff * W_N +
                   upw_W_coeff * W_W + upw_S_coeff * W_S + DDRDAM)
        upw_residual = upw_rhs - upw_denom * W0

        # ------------------------------------------------------------------
        # B. CENTRAL-DIFFERENCE stencil coefficients
        #
        # Central differencing uses symmetric first derivatives:
        #   dW/dr ~ (W_E - W_W) / (2*DR)
        #   dW/dalpha ~ (W_N - W_S) / (2*DA)
        #
        # The W equation is:
        #   nabla_1^2 W + D = (1/r)(DELTA * dW/dr - GAMMA * dW/dalpha)
        #
        # where DELTA = DA - (1/2)(PHI(I,J+1)-PHI(I,J-1))
        #       GAMMA = (1/2)(PHI(I+1,J)-PHI(I-1,J))
        #
        # Expanding nabla_1^2 W on the stencil and multiplying by DR*DA:
        #
        #   Laplacian part (already in the code as ee, ef terms):
        #     DADR*(W_E - 2*W0 + W_W) + EF*(W_N - 2*W0 + W_S) + (DA*rinv/2)*(W_E - W_W)
        #     ... wait, let me be more careful.
        #
        # Actually the Fortran code's stencil comes from multiplying through
        # by DR*DA. Let me derive the central-difference coefficients properly.
        #
        # nabla_1^2 W = d2W/dr2 + (1/r)*dW/dr + (1/r^2)*d2W/dalpha^2
        #
        # Finite differences (central):
        #   d2W/dr2     ~ (W_E - 2*W0 + W_W) / DR^2
        #   (1/r)*dW/dr ~ (1/r) * (W_E - W_W) / (2*DR)
        #   (1/r^2)*d2W/dalpha^2 ~ (1/r^2) * (W_N - 2*W0 + W_S) / DA^2
        #
        # Convective terms (central):
        #   (DELTA/r) * dW/dr ~ (DELTA/r) * (W_E - W_W) / (2*DR)
        #   (GAMMA/r) * dW/dalpha ~ (GAMMA/r) * (W_N - W_S) / (2*DA)
        #
        # The full equation is:
        #   nabla_1^2 W + D = (1/r)(DELTA * dW/dr - GAMMA * dW/dalpha)
        #
        # Multiply everything by DR * DA:
        #
        #   DA/DR*(W_E - 2*W0 + W_W) + (DA/(2r))*(W_E - W_W)
        #   + DR/DA*(1/r^2)*(W_N - 2*W0 + W_S)
        #   + D*DR*DA
        #   = (DELTA/r) * (DA/(2*1)) * (W_E - W_W)     ... wait, need to be more careful.
        #
        # Let me redo this multiplication properly.
        #
        # Starting from:
        #   (W_E - 2*W0 + W_W)/DR^2 + (1/r)*(W_E - W_W)/(2*DR)
        #   + (1/r^2)*(W_N - 2*W0 + W_S)/DA^2
        #   + D
        #   = (DELTA/r)*(W_E - W_W)/(2*DR) - (GAMMA/r)*(W_N - W_S)/(2*DA)
        #
        # Multiply by DR*DA:
        #
        #   (DA/DR)*(W_E - 2*W0 + W_W) + (DA/(2*r))*(W_E - W_W)
        #   + (DR/DA)*(1/r^2)*(W_N - 2*W0 + W_S)
        #   + D*DR*DA
        #   = (DELTA/(2*r))*(DA/DR)*DR*(W_E - W_W)/(DA) ... no, let me just
        #     multiply each term.
        #
        # (DELTA/r)*(W_E - W_W)/(2*DR) * DR*DA = (DELTA*DA)/(2*r) * (W_E - W_W)
        #   Hmm, that doesn't simplify nicely. Let me instead just multiply by DR*DA:
        #
        # LHS * DR*DA:
        #   DADR*(W_E - 2*W0 + W_W) + (DA*rinv/2)*(W_E - W_W)
        #   + DRDA*rinv2*(W_N - 2*W0 + W_S)
        #   + DDRDAM
        #
        # RHS * DR*DA:
        #   DELTA*rinv*(W_E - W_W)*DA/(2) - GAMMA*rinv*(W_N - W_S)*DR/(2)
        #
        # Wait, let me be very precise:
        #   (DELTA/r) * (W_E-W_W)/(2*DR) * (DR*DA) = DELTA*rinv*DA/2 * (W_E-W_W)
        #   (GAMMA/r) * (W_N-W_S)/(2*DA) * (DR*DA) = GAMMA*rinv*DR/2 * (W_N-W_S)
        #
        # So the equation multiplied by DR*DA becomes:
        #
        # DADR*(W_E-2*W0+W_W) + (DA/(2r))*(W_E-W_W) + DRDA/r^2*(W_N-2*W0+W_S) + DDRDAM
        #   = (DELTA*DA/(2r))*(W_E-W_W) - (GAMMA*DR/(2r))*(W_N-W_S)
        #
        # Rearranging (moving convective to LHS):
        #
        # DADR*(W_E-2*W0+W_W) + (DA/(2r))*(W_E-W_W) + DRDA/r^2*(W_N-2*W0+W_S) + DDRDAM
        #   - (DELTA*DA/(2r))*(W_E-W_W) + (GAMMA*DR/(2r))*(W_N-W_S) = 0
        #
        # Hmm, but that includes the Laplacian 1/r * dW/dr term. Looking at the
        # Fortran code more carefully, the stencil is set up differently.
        #
        # Looking at the Fortran: the Laplacian part gives:
        #   EE(I) = 2*(DADR + DRDA*RINV2(I))  -- this is the diagonal
        #
        # For CENTRAL diff, coefficients of W_E, W_W, W_N, W_S are:
        #   W_E: DADR + DELTA*rinv/2    (from d2/dr2 + convective)
        #                                ... but also the 1/r*dW/dr term
        #
        # Actually, let me look at this more carefully. The Fortran code builds
        # the upwind stencil. The stencil WITHOUT the 1/r*dW/dr Laplacian part
        # is in EE(I). Let me check what the actual PDE discretization is.
        #
        # From the Fortran code, the coefficient setup for W interior:
        #
        #   GAMMA = 0.5*(PHI(I+1,J) - PHI(I-1,J))
        #   DELTA = DA - 0.5*(PHI(I,J+1) - PHI(I,J-1))
        #
        #   denom = EE(I) + (1/r)*(|GAMMA| + |DELTA|)
        #   E_coeff(I+1) = DADR + (1/r)*max(DELTA,0)
        #   E_coeff(J+1) = EF(I) + (1/r)*max(GAMMA,0)
        #   E_coeff(I-1) = DADR - (1/r)*min(DELTA,0)   = DADR + (1/r)*max(-DELTA,0)
        #   E_coeff(J-1) = EF(I) - (1/r)*min(GAMMA,0)  = EF(I) + (1/r)*max(-GAMMA,0)
        #   source = DDRDAM
        #
        # The equation is: denom * W0 = sum(coeff*W_neighbor) + DDRDAM
        #
        # For CENTRAL differencing, the convective terms use symmetric differences:
        #   (DELTA/r) * (W_E - W_W) / (2*DR) and (GAMMA/r) * (W_N - W_S) / (2*DA)
        #
        # After multiplying by DR*DA and rearranging to the stencil form, the
        # central-difference coefficients are:
        #
        #   W_E: DADR + DELTA*rinv/2     (note: DELTA/2, not |DELTA|)
        #   W_W: DADR - DELTA*rinv/2
        #   W_N: EF + GAMMA*rinv/2
        #   W_S: EF - GAMMA*rinv/2
        #   denom_central: sum of coefficients = EE(I) (the |..| terms cancel)
        #   source: DDRDAM
        #
        # Wait -- I need to verify that the 1/r dW/dr term from the Laplacian
        # is NOT separately present. Looking at EE(I):
        #   EE(I) = 2*(DADR + DRDA*RINV2)
        #
        # The standard 5-point Laplacian stencil for nabla^2 in polar coords
        # multiplied by DR*DA gives:
        #   d2/dr2 part: DADR*(W_E - 2*W0 + W_W)
        #   (1/r)*d/dr part: (DA/(2r))*(W_E - W_W)     -- using central diff
        #   (1/r^2)*d2/dalpha^2 part: DRDA*RINV2*(W_N - 2*W0 + W_S)
        #
        # Coefficients:
        #   W_E: DADR + DA*rinv/2 = DADR + DA/(2r)
        #   W_W: DADR - DA*rinv/2 = DADR - DA/(2r)
        #   W_N: DRDA*rinv2
        #   W_S: DRDA*rinv2
        #   -W0: 2*DADR + 2*DRDA*rinv2 = EE(I)
        #
        # But looking at the code, the coefficient for W_E in the upwind stencil is:
        #   DADR + rinv * max(DELTA, 0)
        #
        # NOT "DADR + DA*rinv/2 + rinv * max(DELTA, 0)".
        #
        # This means the 1/r dW/dr Laplacian term has been ABSORBED into the
        # convective term! Let me check the PDE formulation.
        #
        # The W equation from the background:
        #   nabla_1^2 w + D = (1/r)(dphi/dalpha * dw/dr - dphi/dr * dw/dalpha)
        #
        # Let's look at the RHS convective term more carefully.
        # dphi/dalpha ~ (PHI(I,J+1) - PHI(I,J-1)) / (2*DA)
        # So (1/r) * dphi/dalpha * dw/dr
        #   = (1/r) * [(PHI(I,J+1)-PHI(I,J-1))/(2*DA)] * dw/dr
        #
        # And DELTA = DA - 0.5*(PHI(I,J+1)-PHI(I,J-1))
        # So 0.5*(PHI(I,J+1)-PHI(I,J-1)) = DA - DELTA
        # And dphi/dalpha ~ (DA - DELTA) * 2 / (2*DA) = (DA - DELTA) / DA
        #
        # Wait, that's not right. Let me re-examine.
        #
        # Actually, looking at the equation:
        #   nabla_1^2 w + D = (1/r)(dphi/dalpha * dw/dr - dphi/dr * dw/dalpha)
        #
        # The Laplacian nabla_1^2 includes the 1/r dw/dr term.
        # Now, dphi/dalpha is discretized, and then:
        #   (1/r) * dphi/dalpha * dw/dr = (1/r) * [(PHI(J+1)-PHI(J-1))/(2*DA)] * dw/dr
        #
        # On the LHS we have:
        #   nabla_1^2 w = d2w/dr2 + (1/r)dw/dr + (1/r^2)d2w/dalpha^2
        #
        # Moving the convective to LHS:
        #   d2w/dr2 + (1/r)dw/dr + (1/r^2)d2w/dalpha^2 + D
        #     - (1/r)*dphi/dalpha*dw/dr + (1/r)*dphi/dr*dw/dalpha = 0
        #
        # Group the dw/dr terms:
        #   d2w/dr2 + [(1/r) - (1/r)*dphi/dalpha]*dw/dr + (1/r^2)d2w/dalpha^2
        #     + (1/r)*dphi/dr*dw/dalpha + D = 0
        #
        # The combined coefficient of dw/dr is:
        #   (1/r)[1 - dphi/dalpha]
        #
        # Discretizing dphi/dalpha ~ (PHI(J+1)-PHI(J-1))/(2*DA):
        #   (1/r)[1 - (PHI(J+1)-PHI(J-1))/(2*DA)]
        #   = (1/r) * [DA - 0.5*(PHI(J+1)-PHI(J-1))] / DA
        #   = (1/r) * DELTA / DA
        #
        # Similarly, dphi/dr ~ (PHI(I+1)-PHI(I-1))/(2*DR), so:
        #   (1/r)*dphi/dr*dw/dalpha = (1/r)*GAMMA/DR * dw/dalpha   ... wait:
        #   dphi/dr ~ (PHI(I+1)-PHI(I-1))/(2*DR) = GAMMA/DR
        #   (1/r)*dphi/dr = (1/r)*GAMMA/DR
        #   (1/r)*dphi/dr*dw/dalpha = (GAMMA/(r*DR)) * dw/dalpha
        #
        #   Hmm, this also doesn't match. Let me reconsider.
        #
        #   GAMMA = 0.5*(PHI(I+1,J) - PHI(I-1,J))
        #   dphi/dr ~ (PHI(I+1)-PHI(I-1))/(2*DR) = GAMMA/DR
        #
        # So the combined coefficient of dw/dalpha (after moving RHS to LHS):
        #   (1/r^2)*d2w/dalpha^2 + (1/r)*(dphi/dr)*dw/dalpha
        #
        # The dw/dalpha term coefficient:
        #   (1/r)*GAMMA/DR
        #
        # Wait, the sign: from the equation, the RHS has -dphi/dr * dw/dalpha,
        # so moving to LHS: +(1/r)*dphi/dr*dw/dalpha = +(GAMMA/(r*DR))*dw/dalpha
        #
        # Now multiply the whole equation by DR*DA:
        #
        # d2w/dr2 * DR*DA:
        #   (DA/DR)*(W_E - 2*W0 + W_W) = DADR*(W_E - 2*W0 + W_W)
        #
        # (DELTA/(r*DA)) * dw/dr * DR*DA = DELTA/r * (W_E - W_W)/2
        #   (using central diff for dw/dr: (W_E-W_W)/(2*DR), times DR*DA)
        #   = (DELTA*DA)/(2*r*DA) * ... let me just do it step by step.
        #
        # Combined dw/dr coefficient: (1/r)*DELTA/DA
        # dw/dr ~ (W_E - W_W) / (2*DR)   [central]
        # Multiply by DR*DA:
        #   (DELTA/(r*DA)) * (W_E-W_W)/(2*DR) * DR*DA = (DELTA/(2*r)) * (W_E-W_W)
        #
        # (1/r^2)*d2w/dalpha^2 * DR*DA:
        #   (DR/DA)/r^2 * (W_N - 2*W0 + W_S) = DRDA*rinv2*(W_N - 2*W0 + W_S)
        #   = EF * (W_N - 2*W0 + W_S)     (since EF = DRDA*rinv2)
        #
        # GAMMA/(r*DR) * dw/dalpha * DR*DA:
        #   dw/dalpha ~ (W_N - W_S) / (2*DA)
        #   (GAMMA/(r*DR)) * (W_N-W_S)/(2*DA) * DR*DA = (GAMMA/(2*r)) * (W_N-W_S)
        #
        # D * DR*DA = DDRDAM
        #
        # Collecting everything (central diff):
        #   DADR*(W_E - 2*W0 + W_W)
        #   + (DELTA/(2r))*(W_E - W_W)
        #   + EF*(W_N - 2*W0 + W_S)
        #   + (GAMMA/(2r))*(W_N - W_S)
        #   + DDRDAM = 0
        #
        # So the central-diff coefficients (for the stencil: coeff*W = ...) are:
        #   W_E: DADR + DELTA/(2r)
        #   W_W: DADR - DELTA/(2r)
        #   W_N: EF + GAMMA/(2r)
        #   W_S: EF - GAMMA/(2r)
        #   W_0 (diagonal, negative): -2*DADR - 2*EF = -EE
        #   source: DDRDAM
        #
        # Equation: EE*W0 = (DADR+DELTA/(2r))*W_E + (DADR-DELTA/(2r))*W_W
        #                  + (EF+GAMMA/(2r))*W_N + (EF-GAMMA/(2r))*W_S + DDRDAM
        # ------------------------------------------------------------------

        # Central-difference coefficients (unnormalized)
        cen_E_coeff = DADR + DELTA * rinv / 2.0
        cen_W_coeff = DADR - DELTA * rinv / 2.0
        cen_N_coeff = ef + GAMMA * rinv / 2.0
        cen_S_coeff = ef - GAMMA * rinv / 2.0
        cen_denom = ee  # = 2*(DADR + EF) -- doesn't include |DELTA|, |GAMMA|

        # Verify central coefficient sum = ee
        cen_sum = cen_E_coeff + cen_W_coeff + cen_N_coeff + cen_S_coeff
        assert abs(cen_sum - cen_denom) < 1e-12, \
            f"Central coeff sum check failed: {cen_sum} != {cen_denom}"

        # Central-difference residual (should be ~0 if solution were exact CD solution)
        cen_rhs = (cen_E_coeff * W_E + cen_W_coeff * W_W +
                   cen_N_coeff * W_N + cen_S_coeff * W_S + DDRDAM)
        cen_residual = cen_rhs - cen_denom * W0

        # ------------------------------------------------------------------
        # C. Fox correction C_0 (from C&D eq. 13)
        #
        #   C_0 = -0.5/r * [ |DELTA| * (W_E + W_W - 2*W0)
        #                   + |GAMMA| * (W_N + W_S - 2*W0) ]
        #
        # This is the difference: upwind_source - central_source in the
        # unnormalized equation. It corrects the upwind to match central.
        # ------------------------------------------------------------------
        C0 = -0.5 * rinv * (
            abs(DELTA) * (W_E + W_W - 2.0 * W0) +
            abs(GAMMA) * (W_N + W_S - 2.0 * W0)
        )

        # ------------------------------------------------------------------
        # D. Verify the identity: upwind_residual + C_0 = central_diff_residual
        # ------------------------------------------------------------------
        # The difference between the two stencils (upwind - central) is exactly
        # accounted for by C_0.
        #
        # upwind equation: upw_denom*W0 = upw_E*W_E + ... + DDRDAM + C0
        #                  i.e., upw_residual_with_C0 = upw_E*W_E + ... + DDRDAM + C0 - upw_denom*W0
        #
        # So: upw_residual + C0 should equal cen_residual
        #
        # Let's verify this algebraically:
        # upw_rhs + C0 - upw_denom*W0  vs  cen_rhs - cen_denom*W0
        # i.e., (upw_residual + C0) vs cen_residual

        identity_lhs = upw_residual + C0
        identity_rhs = cen_residual
        error = identity_lhs - identity_rhs
        rel_scale = max(abs(identity_lhs), abs(identity_rhs), abs(DDRDAM))
        rel_err = abs(error) / rel_scale if rel_scale > 0 else 0.0

        max_error = max(max_error, abs(error))

        print(f"  ({II:2d},{JJ:2d})    | "
              f"{DELTA:12.6f} {GAMMA:12.6f} | "
              f"{upw_residual:14.6e} {cen_residual:14.6e} {C0:14.6e} | "
              f"{error:14.6e} {rel_err:14.6e}")

    # ------------------------------------------------------------------
    # 6. Now let's PROVE the identity algebraically
    # ------------------------------------------------------------------
    print("\n" + "=" * 72)
    print("ALGEBRAIC PROOF")
    print("=" * 72)
    print("""
The identity upwind_residual + C_0 = central_diff_residual can be proved
by expanding both sides.

Define:
  DELTA, GAMMA as above.
  W_E, W_W, W_N, W_S, W0 = W at compass-direction neighbors and center.
  rinv = 1/r, EE = 2*(DADR + EF), EF = DRDA*rinv^2.

UPWIND stencil (equation * DR*DA, moved to residual form):
  upw_residual = [DADR + rinv*max(DELTA,0)] * W_E
               + [EF + rinv*max(GAMMA,0)] * W_N
               + [DADR - rinv*min(DELTA,0)] * W_W
               + [EF - rinv*min(GAMMA,0)] * W_S
               + DDRDAM
               - [EE + rinv*(|DELTA| + |GAMMA|)] * W0

CENTRAL stencil:
  cen_residual = [DADR + DELTA*rinv/2] * W_E
               + [EF + GAMMA*rinv/2] * W_N
               + [DADR - DELTA*rinv/2] * W_W
               + [EF - GAMMA*rinv/2] * W_S
               + DDRDAM
               - EE * W0

Fox correction:
  C_0 = -0.5*rinv * [|DELTA|*(W_E + W_W - 2*W0) + |GAMMA|*(W_N + W_S - 2*W0)]

Now compute upw_residual + C_0:
  = upw_residual + C_0

Consider the W_E coefficient:
  upw:  DADR + rinv*max(DELTA,0)
  C_0 contributes: -0.5*rinv*|DELTA| to W_E
  sum:  DADR + rinv*max(DELTA,0) - 0.5*rinv*|DELTA|
      = DADR + rinv*[max(DELTA,0) - |DELTA|/2]

  Key identity: max(x,0) - |x|/2 = x/2  for all x.
    Proof: if x >= 0: max(x,0) = x, |x| = x, so x - x/2 = x/2.
           if x < 0:  max(x,0) = 0, |x| = -x, so 0 - (-x)/2 = x/2.

  So: DADR + rinv*DELTA/2  = central W_E coefficient.  CHECK!

Similarly for W_W:
  upw:  DADR - rinv*min(DELTA,0) = DADR + rinv*max(-DELTA,0)
  C_0 contributes: -0.5*rinv*|DELTA| to W_W
  sum:  DADR + rinv*max(-DELTA,0) - 0.5*rinv*|DELTA|
      = DADR + rinv*[max(-DELTA,0) - |DELTA|/2]
      = DADR + rinv*(-DELTA/2)  [by the same identity with x = -DELTA]
      = DADR - rinv*DELTA/2  = central W_W coefficient.  CHECK!

For W_N:
  upw:  EF + rinv*max(GAMMA,0)
  C_0 contributes: -0.5*rinv*|GAMMA|
  sum:  EF + rinv*[max(GAMMA,0) - |GAMMA|/2] = EF + rinv*GAMMA/2.  CHECK!

For W_S:
  upw:  EF - rinv*min(GAMMA,0) = EF + rinv*max(-GAMMA,0)
  C_0 contributes: -0.5*rinv*|GAMMA|
  sum:  EF + rinv*[max(-GAMMA,0) - |GAMMA|/2] = EF - rinv*GAMMA/2.  CHECK!

For W0 (diagonal):
  upw:  -(EE + rinv*(|DELTA| + |GAMMA|))
  C_0 contributes: +0.5*rinv*2*|DELTA| + 0.5*rinv*2*|GAMMA|
                  = rinv*(|DELTA| + |GAMMA|)
  sum:  -EE - rinv*(|DELTA|+|GAMMA|) + rinv*(|DELTA|+|GAMMA|) = -EE.  CHECK!

Source: DDRDAM is the same in both.

Therefore: upwind_residual + C_0 = central_residual  EXACTLY.  QED.
""")

    # ------------------------------------------------------------------
    # 7. Comprehensive sweep over ALL interior points
    # ------------------------------------------------------------------
    print("=" * 72)
    print("COMPREHENSIVE SWEEP: Verifying identity at ALL interior points")
    print("=" * 72)

    all_errors = []
    all_upw_residuals = []
    all_cen_residuals = []
    all_C0 = []

    for II in range(2, NR + 1):
        for JJ in range(2, NA + 1):
            DELTA = DA - 0.5 * (PHI(II, JJ + 1) - PHI(II, JJ - 1))
            GAMMA = 0.5 * (PHI(II + 1, JJ) - PHI(II - 1, JJ))

            rinv = RINV(II)
            ee_val = EE(II)
            ef_val = EF(II)

            W0 = W(II, JJ)
            W_E = W(II + 1, JJ)
            W_W = W(II - 1, JJ)
            W_N = W(II, JJ + 1)
            W_S = W(II, JJ - 1)

            # Upwind
            upw_E = DADR + rinv * max(DELTA, 0.0)
            upw_N = ef_val + rinv * max(GAMMA, 0.0)
            upw_W = DADR - rinv * min(DELTA, 0.0)
            upw_S = ef_val - rinv * min(GAMMA, 0.0)
            upw_den = ee_val + rinv * (abs(GAMMA) + abs(DELTA))
            upw_res = (upw_E * W_E + upw_N * W_N +
                       upw_W * W_W + upw_S * W_S + DDRDAM) - upw_den * W0

            # Central
            cen_E = DADR + DELTA * rinv / 2.0
            cen_W_ = DADR - DELTA * rinv / 2.0
            cen_N = ef_val + GAMMA * rinv / 2.0
            cen_S = ef_val - GAMMA * rinv / 2.0
            cen_res = (cen_E * W_E + cen_W_ * W_W +
                       cen_N * W_N + cen_S * W_S + DDRDAM) - ee_val * W0

            # Fox correction
            c0 = -0.5 * rinv * (
                abs(DELTA) * (W_E + W_W - 2.0 * W0) +
                abs(GAMMA) * (W_N + W_S - 2.0 * W0)
            )

            err = (upw_res + c0) - cen_res
            all_errors.append(err)
            all_upw_residuals.append(upw_res)
            all_cen_residuals.append(cen_res)
            all_C0.append(c0)

    all_errors = np.array(all_errors)
    all_upw_residuals = np.array(all_upw_residuals)
    all_cen_residuals = np.array(all_cen_residuals)
    all_C0 = np.array(all_C0)

    n_points = len(all_errors)
    print(f"\nNumber of interior points checked: {n_points}")
    print(f"  (Expected: {(NR-1) * (NA-1)} = (NR-1)*(NA-1))")
    print()
    print(f"Identity error = upwind_residual + C_0 - central_residual:")
    print(f"  max |error|   = {np.max(np.abs(all_errors)):.6e}")
    print(f"  mean |error|  = {np.mean(np.abs(all_errors)):.6e}")
    print(f"  (machine eps  = {np.finfo(float).eps:.6e})")
    print()
    print(f"Upwind residuals (should be small for converged solution):")
    print(f"  max |upw_res| = {np.max(np.abs(all_upw_residuals)):.6e}")
    print(f"  mean|upw_res| = {np.mean(np.abs(all_upw_residuals)):.6e}")
    print()
    print(f"Central residuals (should also be small, but NOT solved directly):")
    print(f"  max |cen_res| = {np.max(np.abs(all_cen_residuals)):.6e}")
    print(f"  mean|cen_res| = {np.mean(np.abs(all_cen_residuals)):.6e}")
    print()
    print(f"Fox correction C_0:")
    print(f"  max |C_0|     = {np.max(np.abs(all_C0)):.6e}")
    print(f"  mean|C_0|     = {np.mean(np.abs(all_C0)):.6e}")
    print()

    # Note: The upwind residual will NOT be exactly zero because the solution
    # was converged with the Fox correction included. That is:
    # The SOR solver solves: upw_denom*W0 = sum(upw_coeff*W_nbr) + DDRDAM + C0_frozen
    # So at convergence: upw_res + C0_frozen ~ 0, meaning cen_res ~ 0 as well.
    #
    # But C0_frozen is the FROZEN correction from the previous correction iteration.
    # If corrections have converged, then C0_frozen ~ C0_current, and so
    # both upw_res + C0 ~ 0 and cen_res ~ 0.

    print("=" * 72)
    print("INTERPRETATION")
    print("=" * 72)
    print("""
The SOR solver uses the UPWIND stencil with a FROZEN Fox correction C_0
as an additional source term. At convergence of the SOR:

    upw_denom * W0 = sum(upw_coeff * W_nbr) + DDRDAM + C_0_frozen

This means:  upw_residual + C_0_frozen = 0   (approximately)

If the correction iterations have also converged (C_0_frozen ~ C_0_current),
then the algebraic identity guarantees:

    central_residual = upw_residual + C_0 ~ 0

So the converged solution satisfies the CENTRAL-DIFFERENCE equation,
even though only the UPWIND solver was used!
""")

    print(f"Verification that upwind_res + C_0 ~ 0 (SOR convergence):")
    combined = all_upw_residuals + all_C0
    print(f"  max |upw_res + C_0| = {np.max(np.abs(combined)):.6e}")
    print(f"  mean|upw_res + C_0| = {np.mean(np.abs(combined)):.6e}")
    print()
    print(f"Verification that central_res ~ 0 (effective central accuracy):")
    print(f"  max |cen_res|       = {np.max(np.abs(all_cen_residuals)):.6e}")
    print(f"  mean|cen_res|       = {np.mean(np.abs(all_cen_residuals)):.6e}")

    # ------------------------------------------------------------------
    # 8. Report phi_M and w_M
    # ------------------------------------------------------------------
    print()
    print("=" * 72)
    print("SOLUTION SUMMARY for D = 500")
    print("=" * 72)
    print(f"  phi_M = {phi_M:.6f}")
    print(f"  w_M   = {w_M:.6f}")
    print(f"  QR    = {QR:.6f}")

    # Find location of phi_M and w_M
    phi_loc = np.unravel_index(np.argmax(np.abs(PHI_raw)), PHI_raw.shape)
    w_loc = np.unravel_index(np.argmax(np.abs(W_raw)), W_raw.shape)
    print(f"  phi_M location: I={phi_loc[0]+1}, J={phi_loc[1]+1} "
          f"(r={r_val(phi_loc[0]+1):.4f}, alpha={((phi_loc[1])*DA):.4f} rad)")
    print(f"  w_M   location: I={w_loc[0]+1}, J={w_loc[1]+1} "
          f"(r={r_val(w_loc[0]+1):.4f}, alpha={((w_loc[1])*DA):.4f} rad)")

    # ------------------------------------------------------------------
    # Final verdict
    # ------------------------------------------------------------------
    print()
    print("=" * 72)
    identity_max_err = np.max(np.abs(all_errors))
    if identity_max_err < 1e-10:
        print("VERDICT: Fox correction is ALGEBRAICALLY EXACT.")
        print(f"  Identity error is at machine precision: {identity_max_err:.6e}")
    else:
        print(f"VERDICT: Identity error = {identity_max_err:.6e}")
        print("  (Check if this is within acceptable numerical tolerance.)")
    print("=" * 72)

    return 0


if __name__ == "__main__":
    sys.exit(main())
