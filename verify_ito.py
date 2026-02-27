#!/usr/bin/env python
"""Verify turbulent Dean flow friction factor against Ito (1959) correlation.

Reads FRICTION: lines from solver output and checks:
1. At least 4 cases with D >= 1000 (turbulent regime)
2. For each turbulent case: f_c within TOLERANCE of Ito (1959)
3. Re > 0 for all cases

Ito (1959) correlation (Darcy friction factor, smooth wall, turbulent):
    f_c = 0.304 * Re^(-0.25) * (R/a)^(-0.05)

Expected line format:
    FRICTION: D=  1000.00  Re=   4472.14  f_c=  0.043210  f_0_Blasius=  0.041234  f_c/f_0=  1.048

Usage:
    python verify_ito.py <solver_output_file>

Exit 0 = PASS, Exit 1 = FAIL.
"""
import sys
import re
import math

R_OVER_A = 20.0       # Collins & Dennis geometry: R/a = 20
TOLERANCE = 0.20      # 20% tolerance for automated gating
TARGET_TOL = 0.15     # 15% aspirational target (noted but not blocking)
D_TURB_MIN = 1000.0   # Dean number threshold for turbulent regime


def ito_fc(Re, R_over_a=R_OVER_A):
    """Ito (1959) Darcy friction factor for turbulent curved pipe."""
    return 0.304 * Re**(-0.25) * R_over_a**(-0.05)


def blasius_f0(Re):
    """Blasius Darcy friction factor for turbulent straight pipe."""
    return 0.316 * Re**(-0.25)


def main():
    if len(sys.argv) < 2:
        print("Usage: python verify_ito.py <solver_output_file>")
        sys.exit(1)

    try:
        lines = open(sys.argv[1]).readlines()
    except FileNotFoundError:
        print(f"FAIL: Output file '{sys.argv[1]}' not found")
        sys.exit(1)

    cases = []
    for line in lines:
        m = re.search(
            r'FRICTION:.*D=\s*([0-9.eE+-]+).*Re=\s*([0-9.eE+-]+).*f_c=\s*([0-9.eE+-]+)',
            line
        )
        if m:
            D = float(m.group(1))
            Re = float(m.group(2))
            fc = float(m.group(3))
            cases.append((D, Re, fc))

    if len(cases) == 0:
        print("FAIL: No FRICTION: lines found in output")
        sys.exit(1)

    turb_cases = [(D, Re, fc) for D, Re, fc in cases if D >= D_TURB_MIN]

    if len(turb_cases) < 4:
        print(f"FAIL: Only {len(turb_cases)} turbulent cases (D >= {D_TURB_MIN}) found, need >= 4")
        sys.exit(1)

    print(f"{'D':>8}  {'Re':>10}  {'f_c (solver)':>14}  {'f_c (Ito)':>12}  "
          f"{'f_c/f0 (Ito)':>13}  {'rel_err':>9}  {'status'}")
    print("-" * 90)

    fail_count = 0
    warn_count = 0
    for D, Re, fc in sorted(turb_cases):
        if Re <= 0:
            print(f"FAIL: Re = {Re} <= 0 at D = {D}")
            fail_count += 1
            continue
        fc_ito = ito_fc(Re)
        f0 = blasius_f0(Re)
        rel_err = abs(fc - fc_ito) / fc_ito
        if rel_err >= TOLERANCE:
            status = "FAIL"
            fail_count += 1
        elif rel_err >= TARGET_TOL:
            status = "warn"
            warn_count += 1
        else:
            status = "OK"
        print(f"{D:>8.1f}  {Re:>10.2f}  {fc:>14.6f}  {fc_ito:>12.6f}  "
              f"{fc_ito/f0:>13.4f}  {rel_err:>9.4f}  {status}")

    print()
    if fail_count > 0:
        print(f"FAIL: {fail_count}/{len(turb_cases)} turbulent cases exceed "
              f"{TOLERANCE*100:.0f}% Ito tolerance")
        sys.exit(1)
    if warn_count > 0:
        print(f"PASS (with warnings): {warn_count}/{len(turb_cases)} cases exceed "
              f"{TARGET_TOL*100:.0f}% aspirational target (within {TOLERANCE*100:.0f}% gate)")
    else:
        print(f"PASS: All {len(turb_cases)} turbulent cases within "
              f"{TARGET_TOL*100:.0f}% of Ito (1959)")
    sys.exit(0)


if __name__ == "__main__":
    main()
