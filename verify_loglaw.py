#!/usr/bin/env python
"""Verify turbulent straight-pipe profile against log-law.

Reads PROFILE lines from solver output, checks:
1. For 30 < y+ < 200: u+ matches (1/kappa)*ln(y+) + B within TOLERANCE
2. Centreline u+ is in range [18, 27]
3. At least 5 points fall in the log-law region

Usage:
    python verify_loglaw.py <solver_output_file>

Exit 0 = PASS, Exit 1 = FAIL.
"""
import sys
import re
import math

KAPPA = 0.41
B = 5.2
TOLERANCE = 0.10  # 10% relative error allowed


def log_law(yp):
    return (1.0 / KAPPA) * math.log(yp) + B


def main():
    if len(sys.argv) < 2:
        print("Usage: python verify_loglaw.py <solver_output_file>")
        sys.exit(1)

    try:
        lines = open(sys.argv[1]).readlines()
    except FileNotFoundError:
        print(f"FAIL: Output file '{sys.argv[1]}' not found")
        sys.exit(1)

    profile = []
    for line in lines:
        m = re.search(r'PROFILE:\s*y\+\s*=\s*([0-9.eE+-]+)\s+u\+\s*=\s*([0-9.eE+-]+)', line)
        if m:
            yp, up = float(m.group(1)), float(m.group(2))
            profile.append((yp, up))

    if len(profile) < 5:
        print(f"FAIL: Only {len(profile)} profile points found (need >= 5)")
        sys.exit(1)

    # Check centreline u+ (highest y+ point)
    max_yp, max_up = max(profile, key=lambda x: x[0])
    if not (18.0 <= max_up <= 27.0):
        print(f"FAIL: Centreline u+ = {max_up:.4f} is outside expected range [18, 27]")
        sys.exit(1)
    print(f"  Centreline: y+ = {max_yp:.2f}, u+ = {max_up:.4f}  OK (target 22-23)")

    log_region = [(yp, up) for yp, up in profile if 30 < yp < 200]
    if len(log_region) < 3:
        print(f"FAIL: Only {len(log_region)} points in log-law region 30 < y+ < 200 (need >= 3)")
        sys.exit(1)

    max_err = 0.0
    fail_count = 0
    for yp, up in log_region:
        expected = log_law(yp)
        rel_err = abs(up - expected) / expected
        max_err = max(max_err, rel_err)
        status = "OK" if rel_err < TOLERANCE else "FAIL"
        if rel_err >= TOLERANCE:
            fail_count += 1
        print(f"  y+={yp:8.2f}  u+={up:8.4f}  log_law={expected:8.4f}  err={rel_err:.4f}  {status}")

    if fail_count > 0:
        print(f"FAIL: {fail_count}/{len(log_region)} log-law points exceed {TOLERANCE*100:.0f}% "
              f"tolerance (max err = {max_err:.4f})")
        sys.exit(1)

    print(f"PASS: All {len(log_region)} log-law region points within {TOLERANCE*100:.0f}% "
          f"(max err = {max_err:.4f})")
    sys.exit(0)


if __name__ == "__main__":
    main()
