#!/usr/bin/env python3
"""The three Copper-vs-Polar figures the site may quote (Collin's ruling, 2026-11-18: speed, launch, memory; never
pass counts), recomputed from the rows kept here. The full run, its harness and its caveats: ~/plans/copper-vs-polar-
2026-11-18/REPORT.md on the devbox (branch bench/polar). Same Mac mini as xbench, macOS 27, screen locked; Copper
1.0.20261117.114 (Jev, Fast mode) as a headless probe, Polar 0.2.12 (Chromium 158) as a normal window, 2026-11-18.

  runs.csv          one line per agent task (28 tasks × 2 rounds × 2 browsers): caller_ms = time from the agent's
                    call to the answer (Copper: jev_run over loopback MCP; Polar: polar_start_task → finished, over
                    Polar's cloud MCP)
  launchmem.jsonl   cold launches of a fresh APFS clone of each app: first window, then memory 45 s later

    python3 polar.py        prints the figures and checks them against what the site says
"""
import csv
import json
import os
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))


def figures():
    runs = list(csv.DictReader(open(os.path.join(HERE, "runs.csv"))))
    speed = {arm: statistics.median(int(r["caller_ms"]) for r in runs if r["arm"] == arm and r["pass"] == "1")
             for arm in ("copper", "polar")}
    rows = [json.loads(l) for l in open(os.path.join(HERE, "launchmem.jsonl")) if l.strip()]
    launch = {arm: sorted(r["first_window_ms"] for r in rows if r["arm"] == arm) for arm in ("copper", "polar")}
    memory = {arm: [r["idle_total_mb"] for r in rows if r["arm"] == arm and r.get("url") == "https://example.com/"]
              for arm in ("copper", "polar")}
    return speed, launch, memory


if __name__ == "__main__":
    speed, launch, memory = figures()
    for arm in ("copper", "polar"):
        l = launch[arm]
        print(f"{arm}: task p50 {speed[arm] / 1000:.1f} s · launch → window {statistics.median(l) / 1000:.2f} s "
              f"({l[0] / 1000:.2f}–{l[-1] / 1000:.2f}, n={len(l)}) · memory, example.com open "
              f"{statistics.median(memory[arm]):.0f} MB (n={len(memory[arm])})")
    assert round(speed["copper"] / 1000, 1) == 2.0 and round(speed["polar"] / 1000, 1) == 11.6
    assert round(statistics.median(launch["copper"]) / 1000, 2) == 0.56 and round(statistics.median(launch["polar"]) / 1000, 2) == 3.96
    assert round(statistics.median(memory["copper"])) == 111 and round(statistics.median(memory["polar"]), -1) == 390
    print("matches the site: 2.0 s vs 11.6 s, 0.56 s vs 3.96 s, 111 MB vs 390 MB")
