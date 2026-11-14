#!/usr/bin/env python3
"""One REPORT.md per round for the council: what every track measured, against the targets for a 9.

    python3 perf/hillclimb/report.py LABEL [BASELABEL]      (devbox; reads + writes ~/plans/copper-hillclimb-2026-11-14/out)

Reads out/LABEL/{perf/perf.json, coverage/coverage.json, ux/audit.json + keywin.json, gates/gates.json,
agentbench/summary.md} (whatever exists; a missing track says "not run") and, with BASELABEL, the same
files of the base for before → after. Writes out/LABEL/REPORT.md. Numbers only; reading them is the council's job.
"""
import json, os, sys

OUT = os.path.expanduser(os.environ.get("HC_DEST", "~/plans/copper-hillclimb-2026-11-14/out"))

# (metric, host, target for a 9 from SCOREBOARD.md, which percentile it is judged on)
PERF = [
    ("A1.launch.paint_ms", "mini", "≤300 ms p90", "p90"),
    ("A1.cold.paint_ms", "mini", "≤1200 ms", "p90"),
    ("A2.space_switch.busy_ms", "mini", "≤60 ms p90", "p90"),
    ("A2.space_switch.longest_ms", "mini", "no pass >50 ms", "max"),
    ("A2.space_switch.big.busy_ms", "mini", "≤60 ms p90 (185-tab space)", "p90"),
    ("A2.tab_switch.busy_ms", "mini", "≤40 ms", "p90"),
    ("A3.load.local.overhead_pct", "mini", "≤ bare +10%", "p50"),
    ("A3.load.wikipedia.overhead_pct", "mini", "≤ bare +10%", "p50"),
    ("A3.load.github.overhead_pct", "mini", "≤ bare +10%", "p50"),
    ("A3.load.busy_ms", "mini", "≤150 ms main/load", "p50"),
    ("A4.idle.total_mb", "mini", "≤900 MB", "p50"),
    ("A4.idle.pins_mb", "mini", "(pins never sleep)", "p50"),
    ("A4.idle.nonpins_mb", "mini", "—", "p50"),
    ("A4.loaded.total_mb", "mini", "≤2500 MB after 12 tabs", "p50"),
    ("A5.canvas.big.fps", "laptop", "≥50 fps", "p50"),
    ("A5.canvas.big.zoom_p95_ms", "laptop", "≤33 ms", "p50"),
    ("A5.canvas.big.fps", "mini", "(1×, a floor)", "p50"),
    ("A5.wheel.dropped_pct", "laptop", "≤1% dropped at 120 Hz", "p50"),
    ("A6.idle.cpu_pct", "mini", "≤1%", "p50"),
    ("A6.idle.wakeups_per_s", "mini", "≤40/s", "p50"),
    ("A7.cmdk.key_ms", "mini", "≤10 ms/key", "p90"),
    ("A7.cmdk.longest_ms", "mini", "no pass >16 ms", "max"),
    ("A7.keylat.cmd_k.frame_ms", "mini", "key → pixel", "p50"),
]


def load(label, *path):
    p = os.path.join(OUT, label, *path)
    if not os.path.exists(p):
        return None
    return json.load(open(p)) if p.endswith(".json") else open(p).read()


def val(stat, q):
    if not stat:
        return None
    if "na" in stat:
        return stat["na"]
    return stat.get({"p50": "median"}.get(q, q), stat.get("median"))


def fmt(v):
    return "—" if v is None else (f"{v:g}" if isinstance(v, (int, float)) else str(v)[:60])


def perf_section(label, base):
    p = load(label, "perf", "perf.json")
    if not p:
        return ["## Perf (A)", "", "Not run for this round.", ""]
    arms = p["arms"]
    bp = load(base, "perf", "perf.json") if base else None
    L = ["## Perf (A)", "", f"`perf/perf.md` ({' vs '.join(arms)}, {p['created']}). "]
    for host, m in p["machines"].items():
        ld = m.get("load_during") or {}
        L[-1] += f"{host}: load {ld.get('min')}–{ld.get('max')} (median {ld.get('median')}){' ⚠ ' + m['load_flag'] if m.get('load_flag') else ''}. "
    L += ["", f"| Metric | Target for a 9 | {arms[0]} | " + (f"{arms[1]} (same run) | Δ paired |" if len(arms) == 2 else "") +
          (f" {base} (its run) |" if bp else ""),
          "|---|---|---|" + ("---|---|" if len(arms) == 2 else "") + ("---|" if bp else "")]
    for metric, host, target, q in PERF:
        k = f"{metric}@{host}"
        per = p["metrics"].get(k, {})
        if not per and not (bp and bp["metrics"].get(k)):
            continue
        row = f"| `{metric}` {host} ({q}) | {target} | {fmt(val(per.get(arms[0]), q))} |"
        if len(arms) == 2:
            pd = (p.get("delta", {}).get(k) or {}).get("paired")
            row += f" {fmt(val(per.get(arms[1]), q))} | " + (f"{pd['median']:+g} ({pd['worse']}/{pd['rounds']} worse)" if pd else "—") + " |"
        if bp:
            bper = bp["metrics"].get(k, {})
            row += f" {fmt(val(bper.get(bp['arms'][0]), q))} |"
        L.append(row)
    return L + [""]


def coverage_section(label, base):
    c = load(label, "coverage", "coverage.json")
    if not c:
        return ["## Coverage (C)", "", "Not run for this round.", ""]
    m = c["meta"]
    b = (load(base, "coverage", "coverage.json") or {}).get("meta") if base else None
    L = ["## Coverage (C)", "", f"**{m['score_pct']}%** ({m['counts']}) over {len(c['jobs'])} jobs, {m.get('repeats')} runs, "
         f"{m.get('mode')}, {m.get('host')}" + (f"; base {base}: {b['score_pct']}%" if b else "") + ". "
         f"Flaky: {', '.join(m.get('flaky') or []) or 'none'}.", ""]
    L.append("**C7 safety gates failing** (each caps C7 at 4): " + (", ".join(m.get("gate_fails") or []) or "none ✅"))
    L += ["", "| Group | Pass |" + (" Base |" if b else ""), "|---|---|" + ("---|" if b else "")]
    for g, v in sorted(m.get("groups", {}).items()):
        bv = (b or {}).get("groups", {}).get(g)
        L.append(f"| {g} | {v['pass']} / {v['total']} |" + (f" {bv['pass']} / {bv['total']} |" if b and bv else (" — |" if b else "")))
    bad = [j for j in c["jobs"].values() if j.get("status") in ("fail", "missing")]
    if bad:
        L += ["", "Failing / missing: " + "; ".join(f"`{j['id']}` {j['status']}" + (" 〰" if j.get("flaky") else "") for j in bad)]
    return L + [""]


def gates_section(label):
    p = os.path.join(OUT, label, "gates", "gates.json")  # JSON lines, one per fixture
    g = open(p).read() if os.path.exists(p) else None
    if g is None:
        return ["## Gates (every PR's e2e fixture on the integration build)", "", "Not run (`perf/hillclimb/gates.sh APP SRC`).", ""]
    rows = [json.loads(l) for l in g.splitlines() if l.strip()]
    ok, skip = sum(r["rc"] == "0" for r in rows), sum(r["rc"] == "skip" for r in rows)
    L = ["## Gates (every PR's e2e fixture on the integration build)", "",
         f"{ok} pass · {len(rows) - ok - skip} fail · {skip} skipped — `gates/gates.md`.", ""]
    for r in rows:
        if r["rc"] not in ("0", "skip"):
            L.append(f"- ❌ `{r['name']}` rc {r['rc']}: {r['last']}")
    return L + [""]


def ux_section(label, base):
    a = load(label, "ux", "audit.json")
    if not a:
        return ["## UX (B)", "", "Not run for this round.", ""]
    s = a["summary"]
    b = (load(base, "ux", "audit.json") or {}).get("summary") if base else None
    k = s.get("keywin") or {}
    kw = load(label, "ux", "keywin.json") or {}
    env = kw.get("env", {})
    L = ["## UX (B)", "", "`ux/audit.md` (pictures, contrast, checks), `ux/keywin.json` (B13/B14), `before-after/INDEX.md`.", "",
         "| Measure | " + label + " |" + (f" {base} |" if b else ""), "|---|---|" + ("---|" if b else "")]
    for name, f in [("Contrast ≥ AA (all / R1 surfaces)", lambda x: f"{x.get('contrastPass')}% / {x.get('contrastPassR1')}%"),
                    ("Chrome text < 10 pt", lambda x: x.get("under10pt")), ("Truncated lines", lambda x: x.get("truncatedLines")),
                    ("Keyboard checks pass/fail/n/a", lambda x: "{pass}/{fail}/{na}".format(**x.get("keys", {})))]:
        L.append(f"| {name} | {fmt(f(s))} |" + (f" {fmt(f(b))} |" if b else ""))
    L += ["", f"**B13 key-window run**: key window {env.get('key') or 'none'}, screen locked {env.get('screenLocked')}, "
          f"AX probe {'ready' if env.get('axBlocker') == '' else env.get('axBlocker') or 'not run'}; "
          f"{k.get('pass', 0)} pass · {k.get('fail', 0)} fail · {k.get('na', 0)} n/a; AX surfaces {k.get('axSurfaces')}, "
          f"unnamed controls {k.get('axUnnamed')}; Settings ledger {k.get('settingsControls')} controls, "
          f"{k.get('settingsUnnamed')} unnamed.",
          f"**B14 motion** (Reduce Motion at start: {env.get('reduceMotion')}): "
          + "; ".join(f"{n} still at {v.get('stable_ms')} ms" for n, v in (k.get("motion") or {}).items() if v.get("stable_ms") is not None), ""]
    return L


def main():
    label = sys.argv[1]
    base = sys.argv[2] if len(sys.argv) > 2 else None
    L = [f"# Round report — {label}" + (f" vs {base}" if base else ""), "",
         "Generated by `perf/hillclimb/report.py` from the round's own outputs; targets from SCOREBOARD.md. "
         "Each section links its full table.", ""]
    L += perf_section(label, base) + coverage_section(label, base) + gates_section(label) + ux_section(label, base)
    ab = load(label, "agentbench", "summary.md")
    L += ["## Agent speed (D)", "", "`agentbench/summary.md`" if ab else "Not run for this round.", ""]
    if ab:
        L += [l for l in ab.splitlines() if l.startswith("|")][:12] + [""]
    path = os.path.join(OUT, label, "REPORT.md")
    open(path, "w").write("\n".join(L) + "\n")
    print(path)


if __name__ == "__main__":
    main()
