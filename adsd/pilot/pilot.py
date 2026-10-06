"""ADSD pilot (T-0012): fresh agent, with vs without the adsd library.

    python -m adsd.pilot.pilot setup <root>         # create <root>/armA, <root>/armB
    python -m adsd.pilot.pilot run <root> <arm>     # headless claude in the arm workspace
    python -m adsd.pilot.pilot score <root> <arm>   # compile + run the arm's solver.f90, score
    python -m adsd.pilot.pilot audit <root> <arm>   # transcript: contamination, runs, cost

"Fresh" means a headless `claude -p` started in a workspace outside the
repository, so this project's CLAUDE.md, memory and dev-logs are not loaded.
Both arms get the same model, prompt, tools and budget. Arm B also gets
adsd/ (probes + skills, without the validation code and project docs).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PILOT = Path(__file__).resolve().parent
MODEL = "claude-opus-5-5"
BUDGET_USD = "40"
WALL_SECONDS = 4 * 3600
PROMPT = ("Read TASK.md in the current directory and carry out the task completely. "
          "Work autonomously; nobody will answer questions. Finish by writing REPORT.md.")

# C&D (1975) reference values; grid (b) for D <= 2000, grid (c) for 3500/5000
CD = {96.0: (0.995, 23.34), 500.0: (6.166, 83.50), 605.72: (6.972, 96.24),
      1000.0: (9.308, 140.6), 2000.0: (13.38, 234.9), 3500.0: (17.13, 351.4),
      5000.0: (19.97, 449.3)}
# pure upwind on grid (b), same stabilised iteration with corrections off (T-0012 log)
UPWIND = {96.0: (0.9097, 22.72), 500.0: (5.8690, 79.87), 605.72: (6.7058, 91.33),
          1000.0: (9.0837, 130.75), 2000.0: (13.1683, 214.66), 3500.0: (17.3234, 316.04),
          5000.0: (20.4345, 402.33)}
TOL_FINE = 0.01     # D <= 2000: phi_M and w_M within 1% of C&D (upwind misses by 1.6-8.6%)
TOL_COARSE = 0.03   # D >= 3500: converged, phi_M within 3% of C&D grid (c)


def setup(root: Path) -> None:
    for arm in ("armA", "armB"):
        ws = root / arm
        if ws.exists():
            raise SystemExit(f"{ws} exists; refusing to overwrite")
        ws.mkdir(parents=True)
        shutil.copy(REPO / "Schubert_1972_complete_modern_Fortran.f90", ws)
        task = (PILOT / "TASK.md").read_text()
        if arm == "armB":
            task += (PILOT / "TASK_ADSD_ADDENDUM.md").read_text()
            dst = ws / "adsd"
            dst.mkdir()
            for f in ("__init__.py", "probes.py", "README.md"):
                shutil.copy(REPO / "adsd" / f, dst / f)
            shutil.copytree(REPO / "adsd" / "skills", dst / "skills",
                            ignore=shutil.ignore_patterns("__pycache__", "*.mod"))
            shutil.copytree(REPO / "adsd" / "tests", dst / "tests",
                            ignore=shutil.ignore_patterns("__pycache__"))
        (ws / "TASK.md").write_text(task)
    print(f"workspaces ready under {root}")


def run(root: Path, arm: str) -> int:
    ws = root / arm
    env = {k: v for k, v in os.environ.items() if k != "ANTHROPIC_API_KEY"}
    cmd = ["timeout", str(WALL_SECONDS), "claude", "-p", PROMPT, "--model", MODEL,
           "--output-format", "stream-json", "--verbose",
           # --restricted confines file tools to the workspace and ignores user
           # settings; --strict-mcp-config drops all MCP servers. Bash can still
           # read elsewhere, which the audit checks.
           "--restricted", "--tools", "Bash", "Read", "Edit", "Write", "Glob", "Grep",
           "--strict-mcp-config", "--permission-mode", "acceptEdits",
           "--allowedTools", "Bash", "Read", "Edit", "Write", "Glob", "Grep",
           "--max-budget-usd", BUDGET_USD]
    with open(ws / "transcript.jsonl", "w") as out, open(ws / "stderr.txt", "w") as err:
        return subprocess.run(cmd, cwd=ws, env=env, stdout=out, stderr=err).returncode


RESULT_RE = re.compile(r"RESULT\s+D=\s*([0-9.]+)\s+PHI_M=\s*([-0-9.EeNnAa+]+)\s+"
                       r"W_M=\s*([-0-9.EeNnAa+]+)\s+STATUS=\s*(\w+)")


def score(root: Path, arm: str, timeout: float = 900) -> dict:
    ws = root / arm
    sc = root / f"{arm}-score"
    if sc.exists():
        shutil.rmtree(sc)
    sc.mkdir()
    res: dict = {"arm": arm, "cases": {}, "compiled": False}
    if not (ws / "solver.f90").exists():
        res["error"] = "no solver.f90"
        return res
    shutil.copy(ws / "solver.f90", sc / "solver.f90")
    c = subprocess.run(["gfortran", "-O2", "-o", "solver", "solver.f90"], cwd=sc,
                       capture_output=True, text=True)
    if c.returncode != 0:
        res["error"] = "compile failed: " + c.stderr[-2000:]
        return res
    res["compiled"] = True
    try:
        r = subprocess.run(["./solver"], cwd=sc, capture_output=True, text=True, timeout=timeout)
        out = r.stdout
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        res["timeout"] = True
    (sc / "out.txt").write_text(out)
    found = {}
    for m in RESULT_RE.finditer(out):
        found[round(float(m.group(1)), 2)] = (float(m.group(2)), float(m.group(3)), m.group(4))
    passed = 0
    for d, (pc, wc) in CD.items():
        key = round(d, 2)
        if key not in found:
            res["cases"][str(d)] = {"pass": False, "missing": True}
            continue
        p, w, st = found[key]
        ep, ew = abs(p - pc) / pc, abs(w - wc) / wc
        if d <= 2000:
            ok = ep <= TOL_FINE and ew <= TOL_FINE
        else:
            ok = st.upper().startswith("CONV") and ep <= TOL_COARSE
        passed += ok
        pu, wu = UPWIND[d]
        res["cases"][str(d)] = {"phi_M": p, "w_M": w, "status": st, "err_phi": ep,
                                "err_w": ew, "upwind_err_w": abs(wu - wc) / wc, "pass": bool(ok)}
    res["passed"] = passed
    res["of"] = len(CD)
    return res


def audit(root: Path, arm: str) -> dict:
    ws = root / arm
    tool_calls, bash, cost, turns, final = [], [], None, None, None
    for line in (ws / "transcript.jsonl").read_text().splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "assistant":
            for block in ev.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    tool_calls.append(block)
                    if block.get("name") == "Bash":
                        bash.append(block.get("input", {}).get("command", ""))
        if ev.get("type") == "result":
            cost, turns, final = ev.get("total_cost_usd"), ev.get("num_turns"), ev
    outside = []
    pat = re.compile(r"repos/curved-pipe|\.claude/projects|Collins_Dennis|/Users/[^ ]*/repos")
    for b in tool_calls:
        s = json.dumps(b.get("input", {}))
        if pat.search(s):
            outside.append(s[:300])
    if arm == "armA":
        outside += [json.dumps(b.get("input", {}))[:300] for b in tool_calls
                    if "adsd" in json.dumps(b.get("input", {}))]
    compiles = sum(c.count("gfortran") for c in bash)
    runs = sum(len(re.findall(r"(^|[;&|]\s*|\s)\./[\w.-]+", c)) for c in bash)
    probe_runs = sum("adsd.probes" in c for c in bash)
    names: dict[str, int] = {}
    for b in tool_calls:
        names[b.get("name", "?")] = names.get(b.get("name", "?"), 0) + 1
    return {"arm": arm, "tool_calls": len(tool_calls), "by_tool": names, "compiles": compiles,
            "executions": runs, "probe_runs": probe_runs, "cost_usd": cost, "turns": turns,
            "duration_ms": None if final is None else final.get("duration_ms"),
            "terminal_reason": None if final is None else final.get("terminal_reason"),
            "suspicious_access": outside}


def main(argv: list[str]) -> int:
    op, root = argv[0], Path(argv[1])
    if op == "setup":
        setup(root)
    elif op == "run":
        return run(root, argv[2])
    elif op == "score":
        print(json.dumps(score(root, argv[2]), indent=2))
    elif op == "audit":
        print(json.dumps(audit(root, argv[2]), indent=2))
    else:
        raise SystemExit(__doc__)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
