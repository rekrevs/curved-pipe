"""
Plot turbulent vs laminar Dean flow comparison.

Reads solver stdout output from laminar (cd_central) and turbulent
(cd_turbulent) solvers, produces four comparison figures:

  1. phi_M vs D  -- laminar and turbulent on same axes
  2. w_M vs D    -- laminar and turbulent on same axes
  3. Friction factor vs Re -- solver, Ito (1959), Blasius
  4. u+ vs y+ profiles at multiple D values with log-law overlay

Usage:
    python plot_turbulent_comparison.py [laminar_output] [turbulent_output]

If arguments omitted, runs the solvers directly.
"""

import os
import re
import subprocess
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Constants and paths
# ---------------------------------------------------------------------------
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PLOTS_DIR = os.path.join(BASE_DIR, "plots")

# Collins & Dennis (1975) reference data (Tables 1-2 and 5)
CD1975_D = np.array([96, 500, 605.72, 1000, 2000, 3500, 5000])
CD1975_PHI_M = np.array([0.990, 6.116, 6.911, 9.208, 13.19, 17.13, 19.97])
CD1975_W_M = np.array([23.35, 83.69, 96.53, 141.3, 236.5, 351.4, 449.3])

# Curvature ratio delta = a/R (Collins & Dennis geometry, R/a = 20)
DELTA_CURV = 0.05
R_OVER_A = 1.0 / DELTA_CURV  # = 20

# Critical Dean number for laminar-turbulent transition (delta=0.05)
DE_CRIT = 1130.0


# ---------------------------------------------------------------------------
# Parsing functions
# ---------------------------------------------------------------------------
def parse_laminar_output(text):
    """Parse laminar solver stdout for D, phi_M, w_M.

    Format:
        PHI_M =      0.9939  W_M =       23.34  QR =   0.97657
          Done with case D =    96.00
    """
    results = []
    lines = text.strip().split("\n")
    phi_m = w_m = None
    for line in lines:
        m = re.search(
            r"PHI_M\s*=\s*([\d.]+)\s+W_M\s*=\s*([\d.]+)", line
        )
        if m:
            phi_m = float(m.group(1))
            w_m = float(m.group(2))
        m2 = re.search(r"Done with case D\s*=\s*([\d.]+)", line)
        if m2 and phi_m is not None:
            D = float(m2.group(1))
            results.append({"D": D, "phi_M": phi_m, "w_M": w_m})
            phi_m = w_m = None
    return results


def parse_turbulent_output(text):
    """Parse turbulent solver stdout for D, phi_M, w_M.

    Same PHI_M / Done with case format as laminar.
    """
    return parse_laminar_output(text)


def parse_friction(text):
    """Parse FRICTION: lines from turbulent output.

    Format:
        FRICTION: D= 1000.00  Re=   4472.14  f_c=  0.035941
                  f_0_Blasius=  0.038642  f_c/f_0=  0.9301
    """
    results = []
    for line in text.split("\n"):
        m = re.search(
            r"FRICTION:.*D=\s*([\d.eE+-]+).*Re=\s*([\d.eE+-]+)"
            r".*f_c=\s*([\d.eE+-]+).*f_0_Blasius=\s*([\d.eE+-]+)",
            line,
        )
        if m:
            results.append({
                "D": float(m.group(1)),
                "Re": float(m.group(2)),
                "f_c": float(m.group(3)),
                "f_0": float(m.group(4)),
            })
    return results


def parse_wprofile(text, D_target, tol=1.0):
    """Parse WPROFILE: lines for a specific D value.

    Format:
        WPROFILE: D= 1000.00  I=  1  y+=     20.3070  u+=      4.3267
    """
    yplus = []
    uplus = []
    for line in text.split("\n"):
        m = re.search(
            r"WPROFILE:.*D=\s*([\d.eE+-]+).*I=\s*\d+\s+"
            r"y\+=\s*([\d.eE+-]+)\s+u\+=\s*([\d.eE+-]+)",
            line,
        )
        if m:
            D = float(m.group(1))
            if abs(D - D_target) < tol:
                yp = float(m.group(2))
                up = float(m.group(3))
                if yp > 0:  # skip wall point (y+=0)
                    yplus.append(yp)
                    uplus.append(up)
    return np.array(yplus), np.array(uplus)


# ---------------------------------------------------------------------------
# Ito (1959) and Blasius correlations
# ---------------------------------------------------------------------------
def ito_fc(Re, R_over_a=R_OVER_A):
    """Ito (1959) Darcy friction factor for turbulent curved pipe."""
    return 0.304 * Re**(-0.25) * R_over_a**(-0.05)


def blasius_f0(Re):
    """Blasius Darcy friction factor for turbulent straight pipe."""
    return 0.316 * Re**(-0.25)


# ---------------------------------------------------------------------------
# Figure 1: phi_M vs D -- laminar vs turbulent
# ---------------------------------------------------------------------------
def fig_phi_comparison(lam_data, turb_data, filename):
    """phi_M vs D for laminar and turbulent solvers."""
    fig, ax = plt.subplots(figsize=(8, 5.5))

    # Laminar solver
    lam_D = [d["D"] for d in lam_data]
    lam_phi = [d["phi_M"] for d in lam_data]
    ax.plot(lam_D, lam_phi, "b^-", markersize=7, linewidth=1.5,
            label="Laminar (C&D central, grid b)")

    # Turbulent solver
    turb_D = [d["D"] for d in turb_data]
    turb_phi = [d["phi_M"] for d in turb_data]
    ax.plot(turb_D, turb_phi, "rs-", markersize=8, linewidth=1.5,
            label="Turbulent (Van Driest, grid c)")

    # C&D 1975 reference
    ax.plot(CD1975_D, CD1975_PHI_M, "ko", markersize=6, markerfacecolor="none",
            markeredgewidth=1.5, label="C&D 1975 (paper, laminar)")

    # Transition line
    ax.axvline(DE_CRIT, color="gray", linestyle="--", linewidth=1.0, alpha=0.7)
    ax.text(DE_CRIT * 1.05, ax.get_ylim()[0] + 0.5,
            r"$De_c \approx 1130$", fontsize=9, color="gray", va="bottom")

    ax.set_xscale("log")
    ax.set_xlabel("Dean number $D$", fontsize=12)
    ax.set_ylabel(r"$\phi_M$ (maximum stream function)", fontsize=12)
    ax.set_title(r"Secondary flow strength $\phi_M$ vs $D$: laminar vs turbulent",
                 fontsize=13)
    ax.legend(fontsize=10, loc="upper left")
    ax.grid(True, alpha=0.3, which="both")
    ax.tick_params(labelsize=10)

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 2: w_M vs D -- laminar vs turbulent
# ---------------------------------------------------------------------------
def fig_wm_comparison(lam_data, turb_data, filename):
    """w_M vs D for laminar and turbulent solvers."""
    fig, ax = plt.subplots(figsize=(8, 5.5))

    # Laminar solver
    lam_D = [d["D"] for d in lam_data]
    lam_w = [d["w_M"] for d in lam_data]
    ax.plot(lam_D, lam_w, "b^-", markersize=7, linewidth=1.5,
            label="Laminar (C&D central, grid b)")

    # Turbulent solver
    turb_D = [d["D"] for d in turb_data]
    turb_w = [d["w_M"] for d in turb_data]
    ax.plot(turb_D, turb_w, "rs-", markersize=8, linewidth=1.5,
            label="Turbulent (Van Driest, grid c)")

    # C&D 1975 reference
    ax.plot(CD1975_D, CD1975_W_M, "ko", markersize=6, markerfacecolor="none",
            markeredgewidth=1.5, label="C&D 1975 (paper, laminar)")

    # Transition line
    ax.axvline(DE_CRIT, color="gray", linestyle="--", linewidth=1.0, alpha=0.7)
    ax.text(DE_CRIT * 1.05, 20,
            r"$De_c \approx 1130$", fontsize=9, color="gray", va="bottom")

    ax.set_xscale("log")
    ax.set_xlabel("Dean number $D$", fontsize=12)
    ax.set_ylabel(r"$w_M$ (maximum axial velocity)", fontsize=12)
    ax.set_title(r"Peak axial velocity $w_M$ vs $D$: laminar vs turbulent",
                 fontsize=13)
    ax.legend(fontsize=10, loc="upper left")
    ax.grid(True, alpha=0.3, which="both")
    ax.tick_params(labelsize=10)

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 3: Friction factor vs Re
# ---------------------------------------------------------------------------
def fig_friction(friction_data, filename):
    """Darcy friction factor vs Re: solver, Ito (1959), Blasius."""
    fig, ax = plt.subplots(figsize=(8, 5.5))

    # Solver results
    Re_vals = np.array([d["Re"] for d in friction_data])
    fc_vals = np.array([d["f_c"] for d in friction_data])

    ax.plot(Re_vals, fc_vals, "rs", markersize=10, markeredgewidth=1.5,
            label=r"$f_c$ solver (Van Driest)")

    # Ito (1959) correlation -- continuous curve
    Re_range = np.logspace(np.log10(Re_vals.min() * 0.8),
                           np.log10(Re_vals.max() * 1.2), 200)
    fc_ito = np.array([ito_fc(R) for R in Re_range])
    ax.plot(Re_range, fc_ito, "k-", linewidth=2.0,
            label=r"Ito (1959): $f_c = 0.304\,Re^{-1/4}\,(R/a)^{-0.05}$")

    # Ito +/- 20% band
    ax.fill_between(Re_range, fc_ito * 0.8, fc_ito * 1.2,
                    color="gray", alpha=0.15, label=r"Ito $\pm 20\%$")

    # Blasius (straight pipe)
    f0_blas = np.array([blasius_f0(R) for R in Re_range])
    ax.plot(Re_range, f0_blas, "b--", linewidth=1.5,
            label=r"Blasius: $f_0 = 0.316\,Re^{-1/4}$")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel(r"Reynolds number $Re = D / \sqrt{\delta}$", fontsize=12)
    ax.set_ylabel("Darcy friction factor $f$", fontsize=12)
    ax.set_title(r"Friction factor: turbulent curved pipe ($\delta = 0.05$)",
                 fontsize=13)
    ax.legend(fontsize=9, loc="upper right")
    ax.grid(True, alpha=0.3, which="both")
    ax.tick_params(labelsize=10)

    # Annotate each solver point with its D value
    for d in friction_data:
        ax.annotate(f"D={d['D']:.0f}",
                    (d["Re"], d["f_c"]),
                    textcoords="offset points", xytext=(8, 6),
                    fontsize=8, color="red")

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 4: u+ vs y+ profiles
# ---------------------------------------------------------------------------
def fig_uplus_profile(turb_text, filename):
    """u+ vs y+ at multiple D values, overlaid with log-law and viscous sublayer."""
    fig, ax = plt.subplots(figsize=(8, 6))

    colors = {1000: "C0", 2000: "C1", 3500: "C2", 5000: "C3"}
    markers = {1000: "o", 2000: "s", 3500: "^", 5000: "D"}

    for D_val in [1000, 2000, 3500, 5000]:
        yp, up = parse_wprofile(turb_text, D_val)
        if len(yp) == 0:
            continue
        # Sort by y+ ascending
        idx = np.argsort(yp)
        yp, up = yp[idx], up[idx]
        ax.plot(yp, up, marker=markers[D_val], color=colors[D_val],
                markersize=5, linewidth=1.2, label=f"D = {D_val}")

    # Reference curves
    yp_ref = np.logspace(-0.5, 2.5, 500)

    # Viscous sublayer: u+ = y+
    yp_visc = yp_ref[yp_ref <= 12]
    ax.plot(yp_visc, yp_visc, "k--", linewidth=1.2, label=r"$u^+ = y^+$ (viscous)")

    # Log-law: u+ = (1/kappa) * ln(y+) + B
    kappa = 0.41
    B = 5.2
    yp_log = yp_ref[yp_ref >= 10]
    uplus_log = (1.0 / kappa) * np.log(yp_log) + B
    ax.plot(yp_log, uplus_log, "k-.", linewidth=1.2,
            label=rf"$u^+ = (1/{kappa})\ln y^+ + {B}$ (log-law)")

    ax.set_xscale("log")
    ax.set_xlabel(r"$y^+$", fontsize=13)
    ax.set_ylabel(r"$u^+$", fontsize=13)
    ax.set_title(r"Mean velocity profile $u^+$ vs $y^+$ (outer wall, $\alpha = 0$)",
                 fontsize=13)
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(True, alpha=0.3, which="both")
    ax.tick_params(labelsize=10)

    # Set sensible axis limits
    ax.set_xlim(0.3, 100)
    ax.set_ylim(0, 14)

    # Mark buffer-layer boundaries
    for yp_mark, label in [(5, r"$y^+=5$"), (30, r"$y^+=30$")]:
        ax.axvline(yp_mark, color="gray", linestyle=":", linewidth=0.8, alpha=0.5)
        ax.text(yp_mark, ax.get_ylim()[1] * 0.97, label,
                fontsize=8, color="gray", ha="center", va="top")

    # Note about DNS reference
    ax.text(0.98, 0.03,
            "Note: DNS reference (H\u00fcttl & Friedrich 2001)\nnot digitised; qualitative comparison only",
            transform=ax.transAxes, fontsize=7, ha="right", va="bottom",
            color="gray", fontstyle="italic",
            bbox=dict(boxstyle="round,pad=0.3", facecolor="white",
                      edgecolor="gray", alpha=0.8))

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    os.makedirs(PLOTS_DIR, exist_ok=True)

    # Read or generate solver output
    if len(sys.argv) >= 3:
        lam_file, turb_file = sys.argv[1], sys.argv[2]
        print(f"Reading laminar output from {lam_file}")
        lam_text = open(lam_file).read()
        print(f"Reading turbulent output from {turb_file}")
        turb_text = open(turb_file).read()
    else:
        print("Running laminar solver (cd_central)...")
        lam_result = subprocess.run(
            [os.path.join(BASE_DIR, "cd_central")],
            capture_output=True, text=True, timeout=60,
        )
        lam_text = lam_result.stdout + lam_result.stderr
        print("Running turbulent solver (cd_turbulent)...")
        turb_result = subprocess.run(
            [os.path.join(BASE_DIR, "cd_turbulent")],
            capture_output=True, text=True, timeout=600,
        )
        turb_text = turb_result.stdout + turb_result.stderr

    # Parse results
    lam_data = parse_laminar_output(lam_text)
    turb_data = parse_turbulent_output(turb_text)
    friction_data = parse_friction(turb_text)

    print(f"\nLaminar cases:   {[d['D'] for d in lam_data]}")
    print(f"Turbulent cases: {[d['D'] for d in turb_data]}")
    print(f"Friction data:   {[d['D'] for d in friction_data]}")

    # Generate figures
    print("\nGenerating comparison plots...")

    print("  Figure 1: phi_M vs D")
    fig_phi_comparison(lam_data, turb_data, "turb_phi_M_comparison.png")

    print("  Figure 2: w_M vs D")
    fig_wm_comparison(lam_data, turb_data, "turb_w_M_comparison.png")

    print("  Figure 3: Friction factor vs Re")
    fig_friction(friction_data, "turb_friction_factor.png")

    print("  Figure 4: u+ vs y+ profiles")
    fig_uplus_profile(turb_text, "turb_uplus_profile.png")

    print("\nDone! All turbulent comparison figures saved to plots/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
