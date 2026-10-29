"""Append one line per gds run to metrics_log/summary.csv.

Usage: summarise_metrics.py metrics.json date commit message summary.csv
"""
import csv, json, os, sys

path, day, commit, message, out = sys.argv[1:6]
with open(path) as f:
    m = json.loads(f.read().replace("Infinity", "1e999"))  # metrics.json uses Infinity

def get(key, default=""):
    v = m.get(key, default)
    return "" if v == float("inf") else v

std = get("design__instance__count__stdcell", 0)
tap = get("design__instance__count__class:tap_cell", 0)
row = {
    "date": day,
    "commit": commit,
    "commit message": message.splitlines()[0] if message else "",
    "logic cells": std - tap,
    "std cells": std,
    "tap cells": tap,
    "utilisation %": round(100 * get("design__instance__utilization", 0), 2),
    "setup slack (ns)": round(get("timing__setup__ws", 0), 3),
    "hold slack (ns)": round(get("timing__hold__ws", 0), 3),
    "reg-to-reg setup slack (ns)": "none (no flip-flops)" if m.get("timing__setup_r2r__ws") == float("inf") else round(get("timing__setup_r2r__ws", 0), 3),
    "power (mW)": round(1000 * get("power__total", 0), 4),
    "DRC errors": get("magic__drc_error__count"),
    "LVS errors": get("design__lvs_error__count"),
    "antenna violations": get("route__antenna_violation__count"),
    "lint warnings": get("design__lint_warning__count"),
    "wire length (um)": get("route__wirelength"),
}
new = not os.path.exists(out)
with open(out, "a", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(row))
    if new:
        w.writeheader()
    w.writerow(row)
print(row)
