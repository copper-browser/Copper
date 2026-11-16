#!/usr/bin/env python3
"""Where a space switch's main thread goes, from perf/a2.py rows (Pace steps + pass log, r4 builds).

    python3 perf/a2steps.py OUT [--warm]

Per arm: p50 of each switch's busy, longest pass, and the split of the switch's own pass
(swap start → projection → selected → done → pass end = SwiftUI's update and commit of the rows),
the time to the next pass (`swap.committed`), the slide's go, the page's attach, and what
the passes after the switch's own one cost. --warm keeps switches whose landing tab was warm.
"""
import json, os, statistics, sys

out = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(out, "a2.jsonl"))]
cells = {}
for r in rows:
    for s in r["spaces"]:
        if "busy" not in s or not s.get("steps"):
            continue
        if "--warm" in sys.argv and s.get("landing") != "warm":
            continue
        st = {}
        for name, at in s["steps"]:
            st.setdefault(name, at)
        if "swap" not in st:
            continue
        t0 = st["swap"]
        # the pass holding the swap: the logged pass that starts before it and ends after it
        own = next(((a, ms) for a, ms in s.get("log") or [] if a <= t0 <= a + ms), None)
        c = cells.setdefault(r["arm"], {})
        def put(k, v):
            c.setdefault(k, []).append(v)
        put("busy", s["busy"])
        put("longest", s["longest"])
        for k in ("slide.planned", "swap.projection", "swap.selected", "swap.done", "swap.committed", "slide.go", "page.attach"):
            if k in st:
                put(k, round(st[k] - t0, 1))
        if "slide.begin" in st:
            put("slide.begin(before swap)", round(t0 - st["slide.begin"], 1))
        if own:
            a, ms = own
            put("own.before_swap", round(t0 - a, 1))
            put("own.after_done(SwiftUI)", round(a + ms - st.get("swap.done", t0), 1))
            put("own.pass", ms)
            put("after.passes", round(sum(m for x, m in s["log"] if x > a), 1))
arms = list(cells)
keys = sorted({k for a in arms for k in cells[a]}, key=lambda k: (k not in ("busy", "longest"), k))
print("| ms (p50, n) | " + " | ".join(arms) + " |")
print("|---|" + "---|" * len(arms))
for k in keys:
    def cell(xs):
        return f"{statistics.median(xs):.1f} ({len(xs)})" if xs else "—"
    print(f"| {k} | " + " | ".join(cell(cells[a].get(k, [])) for a in arms) + " |")
