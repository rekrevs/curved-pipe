"""
Plot Dean flow solutions from Basse (2026) upwind solver and our
Collins & Dennis (1975) central-difference solver.

Generates figures comparable to Basse (2026) Figs 1-8:
  1. Contour plots of phi, w, omega (Figs 1, 2, 8)
  2. Scaling of phi_max, w_max vs D (Fig 5)
  3. Flux ratio QR vs D (Fig 6)
  4. Position of w_max vs D (Fig 7)
  5. Comparison contours: Basse vs C&D (Figs 3-4)
"""

import glob
import os
import sys

import matplotlib.pyplot as plt
import numpy as np
from matplotlib import ticker

# ---------------------------------------------------------------------------
# C&D 1975 reference data (Tables 1-2 and 5)
# ---------------------------------------------------------------------------
CD1975_D = np.array([96, 500, 605.72, 1000, 2000, 3500, 5000])
CD1975_PHI_M = np.array([0.990, 6.116, 6.911, 9.208, 13.19, 17.13, 19.97])
CD1975_W_M = np.array([23.35, 83.69, 96.53, 141.3, 236.5, 351.4, 449.3])
CD1975_QR = 1.0 / np.array([1.023, 1.337, 1.389, 1.550, 1.852, 2.165, 2.392])

# Target D values (filter out D-stepping intermediates)
TARGET_D = [10, 96, 100, 250, 500, 605.72, 1000, 2000, 3500, 5000]

PI = np.pi
PLOTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "plots")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def load_dat_file(path):
    """Load a .dat solution file (Basse or C&D format).

    Returns dict with keys: NR, NA, NRP1, NAP1, XI, RHO, EPS, D, QR,
    PHI, W, OMEGA (each NRP1 x NAP1 numpy arrays), phi_M, w_M.
    """
    with open(path, "r") as f:
        tokens = f.read().split()

    idx = 0

    def read_int():
        nonlocal idx
        val = int(tokens[idx]); idx += 1
        return val

    def read_float():
        nonlocal idx
        val = float(tokens[idx]); idx += 1
        return val

    def read_floats(n):
        nonlocal idx
        vals = [float(tokens[idx + k]) for k in range(n)]
        idx += n
        return np.array(vals)

    def read_array_2d(nr1, na1):
        nonlocal idx
        arr = np.zeros((nr1, na1))
        for i in range(nr1):
            for j in range(na1):
                arr[i, j] = float(tokens[idx]); idx += 1
        return arr

    NRP1 = read_int()
    NAP1 = read_int()
    NR = NRP1 - 1
    NA = NAP1 - 1
    XI = read_floats(4)
    RHO = read_floats(3)
    EPS = read_floats(3)
    D = read_float()
    QR = read_float()

    PHI = read_array_2d(NRP1, NAP1)
    W = read_array_2d(NRP1, NAP1)
    OMEGA = read_array_2d(NRP1, NAP1)

    remaining = len(tokens) - idx
    if remaining != 0:
        print(f"  WARNING: {remaining} extra tokens in {path}")

    # Compute phi_M, w_M
    phi_M = np.max(np.abs(PHI))
    w_M = np.max(np.abs(W))

    # Find position of w_max (normalised radius)
    w_loc = np.unravel_index(np.argmax(np.abs(W)), W.shape)
    DR = 1.0 / NR
    r_wmax = w_loc[0] * DR  # i=0 is centre (r=0), i=NR is wall (r=1)

    return dict(
        NR=NR, NA=NA, NRP1=NRP1, NAP1=NAP1,
        XI=XI, RHO=RHO, EPS=EPS, D=D, QR=QR,
        PHI=PHI, W=W, OMEGA=OMEGA,
        phi_M=phi_M, w_M=w_M, r_wmax=r_wmax,
    )


def load_all_files(directory, pattern):
    """Load all .dat files matching pattern. Returns {D_float: data_dict}."""
    files = sorted(glob.glob(os.path.join(directory, pattern)))
    result = {}
    for fpath in files:
        data = load_dat_file(fpath)
        result[data["D"]] = data
    return result


def match_D(D_target, D_keys, tol=1.0):
    """Find the key in D_keys closest to D_target within tolerance."""
    for dk in D_keys:
        if abs(dk - D_target) < tol:
            return dk
    return None


def filter_target_D(all_data, targets=TARGET_D, tol=1.0):
    """Return subset of all_data matching target D values."""
    filtered = {}
    for dt in targets:
        dk = match_D(dt, all_data.keys(), tol)
        if dk is not None:
            filtered[dk] = all_data[dk]
    return filtered


# ---------------------------------------------------------------------------
# Mirroring for full-circle polar plots
# ---------------------------------------------------------------------------
def mirror_field(field, NR, NA, symmetry="antisymmetric"):
    """Mirror upper-half field (alpha in [0, pi]) to full circle.

    The data covers alpha = 0..pi (NA+1 points, indices j=0..NA).
    We mirror to alpha = 0..2*pi (2*NA+1 points).

    symmetry: 'symmetric' (w) or 'antisymmetric' (phi, omega).
    For symmetric fields: f(2*pi - alpha) = f(alpha)
    For antisymmetric: f(2*pi - alpha) = -f(alpha)
    """
    NRP1 = NR + 1
    NAP1 = NA + 1
    # Full circle: 2*NA + 1 points (0 to 2*pi inclusive)
    full = np.zeros((NRP1, 2 * NA + 1))
    # Upper half: alpha = 0..pi
    full[:, :NAP1] = field
    # Lower half: alpha = pi..2*pi (mirror)
    sign = 1.0 if symmetry == "symmetric" else -1.0
    # j_full = NA+1 .. 2*NA maps to j_mirror = NA-1 .. 0
    for k in range(1, NA):
        full[:, NA + k] = sign * field[:, NA - k]
    # Close the circle: alpha = 2*pi = alpha = 0
    full[:, 2 * NA] = field[:, 0]
    return full


def make_polar_grid(NR, NA_full):
    """Create (R, Theta) meshgrid for polar contour plots.

    R from 0 to 1 (NR+1 points), Theta from 0 to 2*pi (NA_full+1 points).
    """
    DR = 1.0 / NR
    r = np.linspace(0, 1, NR + 1)
    theta = np.linspace(0, 2 * PI, NA_full + 1)
    return np.meshgrid(theta, r)


# ---------------------------------------------------------------------------
# Figure 1-3: Contour plots (phi, w, omega)
# ---------------------------------------------------------------------------
def plot_contour_polar(ax, field_full, NR, NA_full, title="", n_levels=20,
                       cmap="RdBu_r"):
    """Plot filled contours on a polar axis."""
    Theta, R = make_polar_grid(NR, NA_full)
    vmax = np.max(np.abs(field_full))
    if vmax == 0:
        vmax = 1.0
    levels = np.linspace(-vmax, vmax, n_levels + 1)
    cf = ax.contourf(Theta, R, field_full, levels=levels, cmap=cmap,
                     extend="both")
    ax.contour(Theta, R, field_full, levels=levels, colors="k",
               linewidths=0.3, alpha=0.5)
    ax.set_title(title, fontsize=10, pad=10)
    ax.set_yticks([0.25, 0.5, 0.75, 1.0])
    ax.set_yticklabels(["", "0.5", "", "1"])
    ax.tick_params(labelsize=7)
    ax.set_rlabel_position(135)
    return cf


def fig_contours(data_dict, field_name, symmetry, D_values, filename):
    """Create multi-panel contour figure for one field at several D values.

    data_dict: {D: data} (already filtered)
    field_name: 'PHI', 'W', or 'OMEGA'
    """
    n = len(D_values)
    fig, axes = plt.subplots(1, n, subplot_kw=dict(projection="polar"),
                             figsize=(4 * n, 4))
    if n == 1:
        axes = [axes]

    field_label = {"PHI": r"$\phi$", "W": r"$w$", "OMEGA": r"$\Omega$"}
    cmap = "RdBu_r"

    for i, Dt in enumerate(D_values):
        dk = match_D(Dt, data_dict.keys())
        if dk is None:
            axes[i].set_title(f"D={Dt}\n(no data)", fontsize=10)
            continue
        d = data_dict[dk]
        field = d[field_name]
        NR, NA = d["NR"], d["NA"]
        full = mirror_field(field, NR, NA, symmetry)
        cf = plot_contour_polar(axes[i], full, NR, 2 * NA,
                                title=f"D = {Dt:g}",
                                cmap=cmap)

    fig.suptitle(f"{field_label.get(field_name, field_name)} — C&D central-difference solver",
                 fontsize=13, y=1.02)
    fig.tight_layout()

    # Shared colorbar — use last successful contourf
    # (each subplot has its own scale, so we add per-subplot colorbars)
    for i, Dt in enumerate(D_values):
        dk = match_D(Dt, data_dict.keys())
        if dk is None:
            continue
        d = data_dict[dk]
        field = d[field_name]
        NR, NA = d["NR"], d["NA"]
        full = mirror_field(field, NR, NA, symmetry)
        vmax = np.max(np.abs(full))
        if vmax > 0:
            # Recreate contourf on existing axis to get mappable for colorbar
            pass  # colorbars already implicit from contourf

    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 5: Scaling plots — phi_max, w_max vs D
# ---------------------------------------------------------------------------
def fig_scaling(cd_data, basse_data, filename):
    """phi_M and w_M vs D for three series: Basse, our C&D, C&D 1975 ref."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Extract data series
    cd_Ds = sorted(cd_data.keys())
    cd_phi = [cd_data[d]["phi_M"] for d in cd_Ds]
    cd_w = [cd_data[d]["w_M"] for d in cd_Ds]

    basse_Ds = sorted(basse_data.keys())
    basse_phi = [basse_data[d]["phi_M"] for d in basse_Ds]
    basse_w = [basse_data[d]["w_M"] for d in basse_Ds]

    # phi_M subplot
    ax1.plot(basse_Ds, basse_phi, "bo-", markersize=7, label="Basse upwind")
    ax1.plot(cd_Ds, cd_phi, "rs-", markersize=6, label="C&D central (ours)")
    ax1.plot(CD1975_D, CD1975_PHI_M, "m^", markersize=8,
             label="C&D 1975 (paper)", markerfacecolor="none", markeredgewidth=1.5)
    ax1.set_xlabel("D (Dean number)")
    ax1.set_ylabel(r"$\phi_{max}$")
    ax1.set_title(r"Maximum stream function $\phi_{max}$ vs D")
    ax1.legend(fontsize=9)
    ax1.grid(True, alpha=0.3)

    # w_M subplot
    ax2.plot(basse_Ds, basse_w, "bo-", markersize=7, label="Basse upwind")
    ax2.plot(cd_Ds, cd_w, "rs-", markersize=6, label="C&D central (ours)")
    ax2.plot(CD1975_D, CD1975_W_M, "m^", markersize=8,
             label="C&D 1975 (paper)", markerfacecolor="none", markeredgewidth=1.5)
    ax2.set_xlabel("D (Dean number)")
    ax2.set_ylabel(r"$w_{max}$")
    ax2.set_title(r"Maximum axial velocity $w_{max}$ vs D")
    ax2.legend(fontsize=9)
    ax2.grid(True, alpha=0.3)

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 6: Flux ratio QR vs D
# ---------------------------------------------------------------------------
def fig_flux_ratio(cd_data, basse_data, filename):
    """QR = Q_curved / Q_straight vs D."""
    fig, ax = plt.subplots(figsize=(7, 5))

    cd_Ds = sorted(cd_data.keys())
    cd_qr = [cd_data[d]["QR"] for d in cd_Ds]

    basse_Ds = sorted(basse_data.keys())
    basse_qr = [basse_data[d]["QR"] for d in basse_Ds]

    ax.plot(basse_Ds, basse_qr, "bo-", markersize=7, label="Basse upwind")
    ax.plot(cd_Ds, cd_qr, "rs-", markersize=6, label="C&D central (ours)")
    ax.plot(CD1975_D, CD1975_QR, "m^", markersize=8,
            label="C&D 1975 (paper)", markerfacecolor="none", markeredgewidth=1.5)
    ax.set_xlabel("D (Dean number)")
    ax.set_ylabel(r"$Q_R = Q_c / Q_s$")
    ax.set_title("Flux ratio vs D")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figure 7: Position of w_max vs D
# ---------------------------------------------------------------------------
def fig_wmax_position(cd_data, basse_data, filename):
    """Normalised radius of |W| maximum vs D."""
    fig, ax = plt.subplots(figsize=(7, 5))

    cd_Ds = sorted(cd_data.keys())
    cd_r = [cd_data[d]["r_wmax"] for d in cd_Ds]

    basse_Ds = sorted(basse_data.keys())
    basse_r = [basse_data[d]["r_wmax"] for d in basse_Ds]

    ax.plot(basse_Ds, basse_r, "bo-", markersize=7, label="Basse upwind")
    ax.plot(cd_Ds, cd_r, "rs-", markersize=6, label="C&D central (ours)")
    ax.set_xlabel("D (Dean number)")
    ax.set_ylabel(r"$r / a$ at $w_{max}$")
    ax.set_title(r"Position of $w_{max}$ vs D")
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)
    ax.set_ylim(0, 1)

    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Figures 3-4: Comparison contours — Basse upwind vs C&D central
# ---------------------------------------------------------------------------
def fig_comparison(cd_data, basse_data, D_values, field_name, symmetry,
                   filename):
    """Side-by-side polar contours: Basse (left) vs C&D (right) at each D."""
    n = len(D_values)
    fig, axes = plt.subplots(n, 2, subplot_kw=dict(projection="polar"),
                             figsize=(8, 4 * n))
    if n == 1:
        axes = axes.reshape(1, 2)

    field_label = {"PHI": r"$\phi$", "W": r"$w$", "OMEGA": r"$\Omega$"}
    cmap = "RdBu_r"

    for row, Dt in enumerate(D_values):
        # Find matching keys
        dk_basse = match_D(Dt, basse_data.keys())
        dk_cd = match_D(Dt, cd_data.keys())

        # Determine shared levels from C&D data (or whichever is available)
        vmax = 0
        for dk, ddata in [(dk_basse, basse_data), (dk_cd, cd_data)]:
            if dk is not None:
                v = np.max(np.abs(ddata[dk][field_name]))
                vmax = max(vmax, v)
        if vmax == 0:
            vmax = 1.0
        levels = np.linspace(-vmax, vmax, 21)

        for col, (dk, ddata, label) in enumerate([
            (dk_basse, basse_data, "Basse upwind"),
            (dk_cd, cd_data, "C&D central"),
        ]):
            ax = axes[row, col]
            if dk is None:
                ax.set_title(f"{label}\nD={Dt:g} (no data)", fontsize=9)
                continue
            d = ddata[dk]
            field = d[field_name]
            NR, NA = d["NR"], d["NA"]
            full = mirror_field(field, NR, NA, symmetry)
            Theta, R = make_polar_grid(NR, 2 * NA)
            ax.contourf(Theta, R, full, levels=levels, cmap=cmap,
                        extend="both")
            ax.contour(Theta, R, full, levels=levels, colors="k",
                       linewidths=0.3, alpha=0.5)
            ax.set_title(f"{label}\nD = {Dt:g}", fontsize=9, pad=10)
            ax.set_yticks([0.25, 0.5, 0.75, 1.0])
            ax.set_yticklabels(["", "0.5", "", "1"])
            ax.tick_params(labelsize=7)
            ax.set_rlabel_position(135)

    fig.suptitle(f"Comparison: {field_label.get(field_name, field_name)}",
                 fontsize=13, y=1.02)
    fig.tight_layout()
    path = os.path.join(PLOTS_DIR, filename)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved {path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))

    print("Loading C&D central-difference data...")
    cd_all = load_all_files(base_dir, "cd_file_D*.dat")
    cd_data = filter_target_D(cd_all)
    print(f"  Loaded {len(cd_all)} files, filtered to {len(cd_data)} target D values:")
    print(f"  D = {sorted(cd_data.keys())}")

    print("Loading Basse upwind data...")
    basse_data = load_all_files(base_dir, "file_D*.dat")
    print(f"  Loaded {len(basse_data)} files:")
    print(f"  D = {sorted(basse_data.keys())}")

    # Create output directory
    os.makedirs(PLOTS_DIR, exist_ok=True)
    print(f"\nOutput directory: {PLOTS_DIR}")

    # --- Contour plots (Figs 1, 2, 8) ---
    contour_D = [96, 500, 1000, 2000, 5000]
    print("\nGenerating contour plots...")
    fig_contours(cd_data, "PHI", "antisymmetric", contour_D, "contour_phi.png")
    fig_contours(cd_data, "W", "symmetric", contour_D, "contour_w.png")
    fig_contours(cd_data, "OMEGA", "antisymmetric", contour_D, "contour_omega.png")

    # --- Scaling plots (Fig 5) ---
    print("\nGenerating scaling plot...")
    fig_scaling(cd_data, basse_data, "scaling_phi_w.png")

    # --- Flux ratio (Fig 6) ---
    print("\nGenerating flux ratio plot...")
    fig_flux_ratio(cd_data, basse_data, "flux_ratio.png")

    # --- w_max position (Fig 7) ---
    print("\nGenerating w_max position plot...")
    fig_wmax_position(cd_data, basse_data, "wmax_position.png")

    # --- Comparison contours (Figs 3-4) ---
    comparison_D = [500, 5000]
    print("\nGenerating comparison contour plots...")
    fig_comparison(cd_data, basse_data, comparison_D, "W", "symmetric",
                   "comparison_w.png")
    fig_comparison(cd_data, basse_data, comparison_D, "PHI", "antisymmetric",
                   "comparison_phi.png")

    print("\nDone! All figures saved to plots/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
