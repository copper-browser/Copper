"""Group × arm table for the Copper vs fastbrowse bench: python3 table.py runs.jsonl
$/run = the LLM calls at the router's list price (luna for fastbrowse, Copper's text model / jev_extract's sonnet) +
Jev input tokens at $0.042/M (Jev's documented price, as fastbrowse's ledger books it); [$1/M] = the harness's usual
assumed Jev price, for comparison with earlier agentbench reports."""
import json
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.expanduser("~/src/copper-hc/perf/hillclimb/agentbench"))
from agentbench import med, pct  # noqa: E402

GROUPS = ("ultrafast", "fbpub", "realweb", "uibench", "wikigame")


def usd(r, jev_per_m):
    return (r.get("cost_usd") or 0) + (r.get("input_tokens") or 0) * jev_per_m / 1e6


rows = [json.loads(line) for line in open(sys.argv[1])]
by = defaultdict(list)
for r in rows:
    by[(r["group"], r["arm"])].append(r)
f = lambda x, d=1: "—" if x is None else f"{x:.{d}f}"  # noqa: E731
print("| Group | Arm | Pass | False DONE | Wall p50 s | Wall p90 s | Steps p50 | Jev calls p50 | LLM calls p50 | $/run | [$/run at Jev $1/M] |")
print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for g in GROUPS + ("all",):
    for a in ("shipped", "fastbrowse"):
        rs = [r for r in rows if r["arm"] == a and (g == "all" or r["group"] == g)]
        if not rs:
            continue
        ok = [r for r in rs if r["pass"]]
        false_done = sum(1 for r in rs if r["status"] == "done" and not r["verified"])
        wall = [r["wall_ms"] / 1000 for r in ok if r.get("wall_ms")]
        llm = [r.get("llm_calls") if a == "fastbrowse" else (r.get("text_calls") or 0) + (1 if r.get("extract_ms") else 0) for r in rs]
        name = "shipped (Copper Turbo)" if a == "shipped" else a
        print(f"| {g} | {name} | {len(ok)}/{len(rs)} ({100 * len(ok) / len(rs):.0f}%) | {false_done} | {f(med(wall))} | {f(pct(wall, .9))} | "
              f"{f(med([r['actions'] for r in ok]), 0)} | {f(med([r['decisions'] for r in rs]), 0)} | {f(med(llm), 0)} | "
              f"{sum(usd(r, 0.042) for r in rs) / len(rs):.4f} | {sum(usd(r, 1.0) for r in rs) / len(rs):.4f} |")
