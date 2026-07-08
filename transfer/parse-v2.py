#!/usr/bin/env python3
"""memcached_test2 v2 parser — reads raw-terminal/*.txt (the ONLY source of truth, per
memcached_test2.md §332) and emits parsed/sweep-full.csv + parsed/sweep-summary.csv.
Filename convention: <config>_<mix>_<vsize>_run<r>.txt

Usage: parse-v2.py <run_dir>
"""
import sys, os, re, csv, glob
from statistics import mean

run_dir = sys.argv[1]
raw = os.path.join(run_dir, "raw-terminal")
rows = []
# memtier "Totals" row: Type Ops/sec Hits/sec Misses/sec Avg p50 p95 p99 KB/sec
tot = re.compile(r"^Totals\s+([\d.]+)\s+([\d.-]+)\s+([\d.-]+)\s+([\d.]+)\s+([\d.]+)\s+[\d.]+\s+([\d.]+)\s+([\d.]+)")
name = re.compile(r"^(?P<config>.+)_(?P<mix>RO|WO)_(?P<vsize>\d+)_run(?P<run>\d+)\.txt$")

for path in sorted(glob.glob(os.path.join(raw, "*.txt"))):
    m = name.match(os.path.basename(path))
    if not m:
        continue
    text = open(path, errors="replace").read()
    # invalid if preflight failed
    if "INVALID:" in text:
        rows.append({**m.groupdict(), "valid": 0, "ops_s": "", "hits_s": "", "misses_s": "",
                     "avg_ms": "", "p50_ms": "", "p99_ms": "", "kb_s": "", "mb_s": ""})
        continue
    mt = None
    for line in text.splitlines():
        g = tot.match(line.strip())
        if g:
            mt = g
    if not mt:
        continue
    ops, hits, miss, avg, p50, p99, kb = (float(mt.group(i)) for i in range(1, 8))
    rows.append({**m.groupdict(), "valid": 1, "ops_s": ops, "hits_s": hits, "misses_s": miss,
                 "avg_ms": avg, "p50_ms": p50, "p99_ms": p99, "kb_s": kb, "mb_s": round(kb/1024, 2)})

os.makedirs(os.path.join(run_dir, "parsed"), exist_ok=True)
cols = ["config", "mix", "vsize", "run", "valid", "ops_s", "hits_s", "misses_s",
        "avg_ms", "p50_ms", "p99_ms", "kb_s", "mb_s"]
full = os.path.join(run_dir, "parsed", "sweep-full.csv")
with open(full, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols); w.writeheader()
    for r in rows: w.writerow(r)

# means over runs, per (config, mix, vsize) — valid rows only
groups = {}
for r in rows:
    if not r["valid"]:
        continue
    k = (r["config"], r["mix"], int(r["vsize"]))
    groups.setdefault(k, []).append(r)
summ = os.path.join(run_dir, "parsed", "sweep-summary.csv")
with open(summ, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["config", "mix", "vsize", "n", "ops_s", "avg_ms", "p50_ms", "p99_ms", "mb_s", "hit_rate"])
    for (cfg, mix, vs) in sorted(groups, key=lambda x: (x[0], x[1], x[2])):
        g = groups[(cfg, mix, vs)]
        hr = ""
        if mix == "RO":
            th = sum(x["hits_s"] for x in g); tm = sum(x["misses_s"] for x in g)
            hr = round(th/(th+tm), 3) if (th+tm) else 0
        w.writerow([cfg, mix, vs, len(g), round(mean(x["ops_s"] for x in g)),
                    round(mean(x["avg_ms"] for x in g), 4), round(mean(x["p50_ms"] for x in g), 4),
                    round(mean(x["p99_ms"] for x in g), 4), round(mean(x["mb_s"] for x in g), 1), hr])

print(f"wrote {full} ({len([r for r in rows if r['valid']])} valid / {len(rows)} runs)")
print(f"wrote {summ} ({len(groups)} config-mix-vsize groups)")
