"""Validate the adsd probes against traces from solver_traces.py.

Each check is a diagnostic hypothesis with a known answer from the project
history (dev-logs T-0001..T-0005) or from a counterfactual run. Prints a table
and exits non-zero if any check fails.

Usage:
    python -m adsd.validation.analyze <workdir>
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

from adsd.probes import check_collapse, diagnose, estimate_spectrum
from adsd.validation.solver_traces import STATE_COLS, load, segment


def _x(seg: dict[str, np.ndarray]) -> np.ndarray:
    return np.column_stack([seg[k] for k in STATE_COLS])


def _fmt(lam: complex) -> str:
    return f"{lam.real:+.3f}{lam.imag:+.3f}i"


def main(argv: list[str]) -> int:
    wd = Path(argv[0])
    checks: list[tuple[str, bool, str]] = []
    rows: list[str] = []

    # --- H1: history (T-0003 state, commit 6d19af9) -------------------------
    p = wd / "history" / "trace.csv"
    if p.exists():
        t = load(p)
        for case in range(1, 11):
            seg = segment(t, case, stepping=False, corr=0)
            if len(seg["case"]) < 5:
                continue
            d = seg["D"][0]
            x = _x(seg)[-400:]
            f = diagnose({k: x[:, i] for i, k in enumerate(STATE_COLS)})
            errs = [g for g in f if g.severity == "error"]
            s = estimate_spectrum(x)
            names = ",".join(g.name for g in f)
            rows.append(f"history D={d:7.1f} n={len(x):4d} regime={s.regime:11s} "
                        f"period={s.period} nonlinear={s.nonlinear} -> {names}")
            if d <= 1000:
                checks.append((f"H1 history D={d:g} converging -> no error finding",
                               not errs, names))
            else:
                ok = any(g.name == "oscillation" for g in errs) and s.regime != "contractive"
                checks.append((f"H1 history D={d:g} limit cycle -> oscillation error", ok,
                               f"{names}; regime={s.regime}, period={s.period}"))

    # --- H2: D-stepping 1000 -> 2000, averaging on/off -------------------------
    for avg in ("on", "off"):
        p = wd / f"stepping-avg-{avg}" / "trace.csv"
        if not p.exists():
            continue
        t = load(p)
        seg = segment(t, 8, stepping=True, corr=0)
        col = check_collapse(seg["phiM"])
        dcol = -1.0 if col is None else float(seg["D"][col.data["first_row_below"]])
        rows.append(f"stepping avg-{avg}: rows={len(seg['case'])} collapse="
                    f"{'none' if col is None else f'at D={dcol:g}'}")
        if avg == "off":
            checks.append(("H2 stepping without averaging -> collapse detected (log: D~1430)",
                           col is not None and 1350 <= dcol <= 1500, f"D={dcol:g}"))
        else:
            checks.append(("H2 stepping with averaging -> no collapse", col is None, str(col)))

    # --- H3/H4: fixed D, averaging on/off --------------------------------------
    lam = {}
    for d in (1300, 1400):
        for avg in ("on", "off"):
            p = wd / f"fixed-D{d}-avg-{avg}" / "trace.csv"
            if not p.exists():
                continue
            t = load(p)
            seg = segment(t, 8, stepping=False, corr=0)
            x = _x(seg)
            s = estimate_spectrum(x[5:125], window=120)
            lam[(d, avg)] = s.eigenvalue
            f = diagnose({k: x[:, i] for i, k in enumerate(STATE_COLS)})
            names = ",".join(g.name for g in f)
            rows.append(f"fixed D={d} avg-{avg}: n={len(x):4d} lambda={_fmt(s.eigenvalue)} "
                        f"|lambda|={s.rho:.3f} theta={s.theta:.2f} period={s.period} "
                        f"regime={s.regime} fit={s.fit_residual:.2f} -> {names}")
            errs = [g for g in f if g.severity == "error"]
            if avg == "on":
                checks.append((f"H3 fixed D={d} with averaging -> contractive",
                               s.regime == "contractive" and not errs, names))
            elif d == 1300:
                checks.append(("H3 fixed D=1300 without averaging -> contractive",
                               s.regime == "contractive" and not errs, names))
            else:
                ok = (s.rho > 1.0 and s.theta > 0.3
                      and any(g.name == "collapse-to-trivial" for g in errs))
                checks.append(("H3 fixed D=1400 without averaging -> unstable complex pair "
                               "+ collapse", ok, f"{_fmt(s.eigenvalue)}; {names}"))
    if (1300, "on") in lam and (1300, "off") in lam:
        pred = (1 + lam[(1300, "off")]) / 2
        meas = lam[(1300, "on")]
        checks.append(("H4 averaging maps lambda -> (1+lambda)/2 at D=1300 (|pred-meas|<0.1)",
                       abs(pred - meas) < 0.1, f"pred {_fmt(pred)} meas {_fmt(meas)}"))

    # --- H5: held-out grid (c), not used while tuning the probes ---------------
    # T-0004 log: "grid (c) has period-3 oscillation at D>=500" without averaging.
    for avg in ("off", "default"):
        p = wd / f"gridc-avg-{avg}" / "trace.csv"
        if not p.exists():
            continue
        t = load(p)
        seg = segment(t, 5, stepping=False, corr=0)
        x = _x(seg)
        s = estimate_spectrum(x[-120:], window=120)
        f = diagnose({k: x[:, i] for i, k in enumerate(STATE_COLS)})
        names = ",".join(g.name for g in f)
        rows.append(f"grid (c) D=500 avg-{avg}: n={len(x):4d} lambda={_fmt(s.eigenvalue)} "
                    f"|lambda|={s.rho:.3f} period={s.period} regime={s.regime} "
                    f"fit={s.fit_residual:.2f} -> {names}")
        if avg == "off":
            osc = [g for g in f if g.name == "oscillation"]
            ok = (s.period == 3 and abs(s.rho - 1) < 0.02 and bool(osc)
                  and "two-cycle-averaging" in osc[0].skills
                  and abs(s.rho_after_averaging - 0.5) < 0.05)
            checks.append(("H5 held-out grid (c) D=500 without averaging -> period-3 cycle, "
                           "averaging predicted to give 0.5", ok,
                           f"{_fmt(s.eigenvalue)}, after avg {s.rho_after_averaging:.3f}"))
        else:
            checks.append(("H5 held-out grid (c) D=500 with averaging -> contractive",
                           s.regime == "contractive" and not any(g.severity == "error" for g in f),
                           names))

    print("\n".join(rows))
    print()
    for name, ok, note in checks:
        print(f"[{'PASS' if ok else 'FAIL'}] {name}  ({note})")
    n_ok = sum(ok for _, ok, _ in checks)
    print(f"\n{n_ok}/{len(checks)} checks passed")
    return 0 if n_ok == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
