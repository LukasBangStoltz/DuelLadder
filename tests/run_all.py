"""Runs every DuelLadder test file and prints a summary. Usage: python tests/run_all.py"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["sim.py", "pools_check.py", "challenge_check.py", "trade_check.py", "badge_check.py", "tournament_check.py",
         "tabs_check.py", "bet_safety_check.py"]

total_pass, failed = 0, []
for name in FILES:
    run = subprocess.run([sys.executable, os.path.join(HERE, name)], capture_output=True, text=True,
                         encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    out = run.stdout + run.stderr
    passes = sum(1 for line in out.splitlines() if line.startswith("PASS"))
    fails = [line for line in out.splitlines() if line.startswith("FAIL")]
    total_pass += passes
    crashed = run.returncode != 0 and not fails
    status = "CRASHED" if crashed else ("ok" if not fails else f"{len(fails)} failed")
    if passes == 0 and not crashed:
        crashed, status = True, "CRASHED (no checks ran)"
    print(f"{name:22} {passes:4} passed  {status}")
    for line in fails:
        print("    " + line)
    if crashed:
        print("    " + out.strip().splitlines()[-1])
    if fails or crashed:
        failed.append(name)

print(f"\n{total_pass} checks passed" + (f", problems in: {', '.join(failed)}" if failed else ", all good"))
sys.exit(1 if failed else 0)
