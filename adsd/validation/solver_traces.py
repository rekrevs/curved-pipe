"""Collect per-iteration traces from historical and counterfactual solver variants.

Validation of the adsd probes on real data (T-0011). Every variant is built
from a git revision of Collins_Dennis_1975_central.f90 plus a trace-only patch
(one WRITE per outer iteration), compiled and run in a scratch directory. The
repository's solver is never modified.

Usage:
    python -m adsd.validation.solver_traces <workdir> [experiment ...]

Experiments:
    history    T-0003 state (commit 6d19af9): before 2-cycle averaging
    stepping   current solver, D-stepping 1000 -> 2000, averaging on vs off
    fixed      current solver, fixed D in {1300, 1400}, averaging on vs off
    gridc      held-out: grid (c), D <= 500, averaging as shipped vs off
"""

from __future__ import annotations

import csv
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
SRC = "Collins_Dennis_1975_central.f90"
T0003 = "6d19af9"

HEADER = "case,corr,iter,stepping,D,phiM,wM,omgM,omgWall,dphi,dw,domg,phiMid,wMid"
TRACE = """        WRITE(77,'(I3,",",I4,",",I6,",",L1,10(",",ES16.8))') ctr, CORR_ITER, IOUT, STEPPING, D, &
          MAXVAL(ABS(PHI(2:NR,2:NA,3))), MAXVAL(ABS(W(2:NR,2:NA,3))), &
          MAXVAL(ABS(OMEGA(2:NR,2:NA,3))), MAXVAL(ABS(OMEGA(NRP1,2:NA,3))), &
          MAXVAL(ABS(PHI(:,:,3)-PHI(:,:,1))), MAXVAL(ABS(W(:,:,3)-W(:,:,1))), &
          MAXVAL(ABS(OMEGA(:,:,3)-OMEGA(:,:,1))), PHI(NR/2,NA/2,3), W(NR/2,NA/2,3)

"""
STEP_MARK = "!------------------- D-stepping check -----------------------------------"
LOOP_MARK = "    DO ctr = 1, NCASES\n"
AVG_COND = """        IF ((NR >= 40 .AND. D_TARGET >= 250._dp .OR. &
             NR <  40 .AND. D_TARGET >= 2000._dp) .AND. IOUT > 1) THEN"""
STATE_COLS = ["phiM", "wM", "omgM", "omgWall", "phiMid", "wMid"]


def _replace_once(s: str, old: str, new: str) -> str:
    if s.count(old) != 1:
        raise ValueError(f"patch anchor found {s.count(old)} times: {old[:60]!r}")
    return s.replace(old, new)


def source(rev: str | None) -> str:
    if rev is None:
        return (REPO / SRC).read_text()
    return subprocess.run(["git", "-C", str(REPO), "show", f"{rev}:{SRC}"],
                          check=True, capture_output=True, text=True).stdout


def instrument(src: str, averaging: bool | None = None, d_case8: float | None = None,
               last_case: int | None = None, maxout: int | None = None,
               grid_c: bool = False) -> str:
    s = _replace_once(src, STEP_MARK, TRACE + STEP_MARK)
    if grid_c:
        s = _replace_once(s, "    INTEGER, PARAMETER :: NR = 2*10, NA = 2*18   ! Grid (b)\n"
                             "    ! INTEGER, PARAMETER :: NR = 4*10, NA = 4*18 ! Grid (c)",
                          "    INTEGER, PARAMETER :: NR = 4*10, NA = 4*18 ! Grid (c)")
    loop = LOOP_MARK
    if last_case is not None:
        loop = loop + f"      IF (ctr > {last_case}) EXIT\n"
    s = _replace_once(s, LOOP_MARK,
                      f"    OPEN(77, FILE='trace.csv', STATUS='REPLACE')\n"
                      f"    WRITE(77,'(A)') '{HEADER}'\n" + loop)
    if averaging is not None:
        s = _replace_once(s, AVG_COND,
                          f"        IF ({'.TRUE.' if averaging else '.FALSE.'} .AND. IOUT > 1) THEN")
    if d_case8 is not None:
        s = _replace_once(s, "605.72_dp, 1000._dp, 2000._dp,", f"605.72_dp, 1000._dp, {d_case8:.1f}_dp,")
    if maxout is not None:
        s = _replace_once(s, "    MAXOUT = 40000", f"    MAXOUT = {maxout}")
    return s


def run(src: str, workdir: Path, timeout: float) -> dict[str, np.ndarray]:
    workdir.mkdir(parents=True, exist_ok=True)
    (workdir / "solver.f90").write_text(src)
    subprocess.run(["gfortran", "-O2", "-o", "solver", "solver.f90"], cwd=workdir,
                   check=True, capture_output=True)
    try:
        with open(workdir / "out.txt", "w") as out:
            subprocess.run(["./solver"], cwd=workdir, stdout=out, stderr=subprocess.STDOUT,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        (workdir / "TIMEOUT").write_text(str(timeout))
    return load(workdir / "trace.csv")


def load(path: Path) -> dict[str, np.ndarray]:
    rows = list(csv.reader(open(path)))
    head = rows[0]
    cols: dict[str, list[float]] = {k: [] for k in head}
    for r in rows[1:]:
        if len(r) != len(head):
            continue
        for k, v in zip(head, r):
            v = v.strip()
            try:
                cols[k].append(1.0 if v == "T" else 0.0 if v == "F" else float(v))
            except ValueError:
                cols[k].append(float("nan"))
    return {k: np.array(v) for k, v in cols.items()}


def segment(t: dict[str, np.ndarray], case: int, stepping: bool, corr: int = 0,
            last: int | None = None) -> dict[str, np.ndarray]:
    m = (t["case"] == case) & (t["stepping"] == float(stepping)) & (t["corr"] == corr)
    out = {k: v[m] for k, v in t.items()}
    if last:
        out = {k: v[-last:] for k, v in out.items()}
    return out


def experiments(workdir: Path, names: list[str]) -> dict[str, dict[str, np.ndarray]]:
    traces = {}
    if "history" in names:
        traces["history"] = run(instrument(source(T0003)), workdir / "history", 600)
    if "stepping" in names:
        for avg in (True, False):
            key = f"stepping-avg-{'on' if avg else 'off'}"
            traces[key] = run(instrument(source(None), averaging=avg, last_case=8, maxout=3000),
                              workdir / key, 300)
    if "fixed" in names:
        for d in (1300.0, 1400.0):
            for avg in (True, False):
                key = f"fixed-D{int(d)}-avg-{'on' if avg else 'off'}"
                traces[key] = run(instrument(source(None), averaging=avg, d_case8=d,
                                             last_case=8, maxout=3000),
                                  workdir / key, 300)
    if "gridc" in names:
        gavg: bool | None
        for gavg in (None, False):
            key = f"gridc-avg-{'off' if gavg is False else 'default'}"
            traces[key] = run(instrument(source(None), averaging=gavg, last_case=5, maxout=3000,
                                         grid_c=True),
                              workdir / key, 900)
    return traces


def main(argv: list[str]) -> int:
    workdir = Path(argv[0])
    names = argv[1:] or ["history", "stepping", "fixed"]
    traces = experiments(workdir, names)
    summary = {k: {"rows": int(len(v["case"]))} for k, v in traces.items()}
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
