#!/usr/bin/env python3
"""audit.md for one evidence pack: chrome-text contrast, font sizes, truncation
(from ocr.jsonl), hit targets + small fonts in code (static.json, if present),
and the scripted keyboard/findability checks (keys.json).

    python3 audit.py OUTDIR [SITEDIR]

Page text is told apart from Copper's own by matching the fixture pages' words
(SITEDIR, default ux/site): anything that is a piece of a fixture page is the
page, the rest is chrome. Sizes are estimates: a Vision line box is about
1.15× the font size (calibrated each run on the fixture's 17 px body text).
"""
import html, json, os, re, statistics, sys

out = sys.argv[1]
site = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")


def norm(s):
    s = s.lower().replace("—", "-").replace("–", "-").replace("…", "...").replace("“", '"').replace("”", '"')
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9.,:;'\"!?()&/+ -]", " ", s)).strip()


page_text = ""
for name in os.listdir(site):
    if name.endswith(".html"):
        raw = open(os.path.join(site, name), encoding="utf-8").read()
        raw = re.sub(r"(?s)<(title|style|script)[^>]*>.*?</\1>", " ", raw)
        page_text += " " + norm(html.unescape(re.sub(r"<[^>]+>", " ", raw)))
PLACEHOLDERS = {"search or enter url...", "search or enter url"}
# macOS's "opens more" ellipsis on a button or row, not a cut-off title.
# shortcut: a fixed list of Copper's own labels, extend when a new one shows up in Truncation.
MENU = re.compile(r"^\W*(clear|customize|delete space|csv file|copper cloud|change|export|import|rename|choose|edit|move in|set up|new \w+|add \w+|open \w+)\s*\.\.\.$")

shots = {r["file"]: r for r in json.load(open(os.path.join(out, "shots.json"))) if r.get("file")}
skipped = [r for r in json.load(open(os.path.join(out, "shots.json"))) if r.get("skipped")]
ocr = [json.loads(l) for l in open(os.path.join(out, "ocr.jsonl"))] if os.path.exists(os.path.join(out, "ocr.jsonl")) else []
keys = json.load(open(os.path.join(out, "keys.json"))) if os.path.exists(os.path.join(out, "keys.json")) else []
static = json.load(open(os.path.join(out, "static.json"))) if os.path.exists(os.path.join(out, "static.json")) else None
run = json.load(open(os.path.join(out, "run.json"))) if os.path.exists(os.path.join(out, "run.json")) else {}

# Calibrate box height → CSS px on the fixture's body paragraphs (17 px).
body = []
for shot in ocr:
    meta = shots.get(shot["file"], {})
    scale = shot["w"] / (1440 if meta.get("size") == "1440" else 1728)
    for l in shot["lines"]:
        if len(l["t"]) > 40 and norm(l["t"]) in page_text and l["h"] / scale < 30:
            body.append(l["h"] / scale / 17)
factor = statistics.median(body) if len(body) > 5 else 1.15

# The window's own chrome (sidebar, toolbar) is counted on the main-* shots only:
# behind a panel's scrim it is dimmed on purpose, and counting it on every
# surface would weigh the sidebar 40 times over.
frame = {}
for shot in ocr:
    meta = shots.get(shot["file"], {})
    if meta.get("surface", "").startswith("main-"):
        frame.setdefault(meta.get("theme"), set()).update(norm(l["t"]) for l in shot["lines"])

chrome = []
for shot in ocr:
    meta = shots.get(shot["file"], {})
    scale = shot["w"] / (1440 if meta.get("size") == "1440" else 1728)
    for l in shot["lines"]:
        t = norm(l["t"])
        if len(t) < 2 or l["c"] < 0.5 or (len(t) > 3 and t in page_text):
            continue
        if not meta.get("surface", "").startswith("main-") and t in frame.get(meta.get("theme"), ()):
            continue
        pt = l["h"] / scale / factor
        chrome.append({"file": shot["file"], "surface": meta.get("surface", "?"), "theme": meta.get("theme", "?"),
                       "size": meta.get("size", "?"), "text": l["t"], "pt": round(pt, 1), "cr": l["cr"],
                       "fg": l["fg"], "bg": l["bg"], "large": pt >= 18,
                       "trunc": (t.endswith("...") or l["t"].endswith("…")) and t not in PLACEHOLDERS and not MENU.match(t)})
need = lambda c: 3.0 if c["large"] else 4.5
fails = [c for c in chrome if c["cr"] < need(c)]
tiny = [c for c in chrome if c["pt"] < 10]
trunc = [c for c in chrome if c["trunc"]]
kpass = sum(1 for k in keys if k["pass"] is True)
kfail = sum(1 for k in keys if k["pass"] is False)
kna = sum(1 for k in keys if k["pass"] is None)

summary = {
    "shots": len(shots), "shotsFailed": sum(1 for r in shots.values() if not r.get("ok")), "notCaptured": [s["surface"] for s in skipped],
    "chromeLines": len(chrome), "contrastPass": round(100 * (1 - len(fails) / max(1, len(chrome))), 1),
    "contrastPassByTheme": {th: round(100 * (1 - sum(1 for c in fails if c["theme"] == th) / max(1, sum(1 for c in chrome if c["theme"] == th))), 1) for th in ("light", "dark")},
    "under10pt": len(tiny), "truncatedLines": len(trunc), "truncatedUnique": len({c["text"] for c in trunc}),
    "medianChromePt": round(statistics.median([c["pt"] for c in chrome]), 1) if chrome else None,
    "keys": {"pass": kpass, "fail": kfail, "na": kna}, "calibration": round(factor, 3),
    "load": run.get("load"), "seconds": run.get("seconds"),
}
if static:
    summary["static"] = {k: static[k] for k in ("smallTargets", "smallFonts") if k in static}
json.dump({"summary": summary, "chrome": chrome, "keys": keys}, open(os.path.join(out, "audit.json"), "w"), indent=1)

L = []
L.append(f"# UX audit — {run.get('label', os.path.basename(os.path.dirname(out)))}\n")
L.append(f"{summary['shots']} pictures ({summary['shotsFailed']} failed), {run.get('seconds', '?')} s, load {run.get('load')}. "
         "Every number below is measured from the pictures (Vision OCR) or the scripted checks; sizes are estimates "
         f"(line box ÷ {factor:.2f}, calibrated on the fixture's 17 px body text).\n")
L.append("| Measure | Value | Bar |\n|---|---|---|")
L.append(f"| Chrome text lines read | {len(chrome)} | — |")
L.append(f"| Contrast ≥ WCAG AA (4.5:1, 3:1 if ≥18 pt) | {summary['contrastPass']}% (light {summary['contrastPassByTheme']['light']}%, dark {summary['contrastPassByTheme']['dark']}%) | 100% |")
L.append(f"| Chrome text under ~10 pt | {len(tiny)} lines | 0 |")
L.append(f"| Median chrome text size | ~{summary['medianChromePt']} pt | 13 pt (macOS body) |")
L.append(f"| Truncated chrome text (…) | {len(trunc)} lines, {summary['truncatedUnique']} distinct | as few as the layout allows |")
L.append(f"| Keyboard + findability checks | {kpass} pass · {kfail} fail · {kna} not measurable | all pass |")
if static:
    L.append(f"| Tappable controls under 24 pt in code | {static.get('smallTargets')} | 0 (WCAG 2.2 target size) |")
    L.append(f"| Font sizes under 11 pt in code | {static.get('smallFonts')} | few, never body text |")
else:
    L.append("| Hit targets | not measured from pictures — run `ux/static.py SRC OUTDIR` | 24 pt |")
L.append("")

L.append("## Keyboard, command bar and Settings findability (scripted)\n")
L.append("| | Cat | Check | Detail |\n|---|---|---|---|")
for k in keys:
    mark = "✅" if k["pass"] is True else ("➖" if k["pass"] is None else "❌")
    L.append(f"| {mark} | {k['category']} | {k['check']} | {str(k['detail']).replace('|', '/')[:160]} |")
L.append("")

L.append("## Contrast — worst chrome text\n")
L.append("Ratio of the line's ink to its ground. Each distinct text once (its worst picture).\n")
L.append("| Ratio | Needs | Text | Surface | Theme | ink / ground |\n|---|---|---|---|---|---|")
seen = set()
for c in sorted(fails, key=lambda c: c["cr"]):
    k = (c["text"], c["theme"])
    if k in seen: continue
    seen.add(k)
    L.append(f"| {c['cr']} | {need(c)} | {c['text'][:60].replace('|', '/')} | {c['surface']} | {c['theme']} | {c['fg']} / {c['bg']} |")
    if len(seen) >= 30: break
L.append("")
L.append("### Contrast by surface (both sizes)\n")
L.append("| Surface | light pass | dark pass | lines |\n|---|---|---|---|")
for s in sorted({c["surface"] for c in chrome}):
    row = []
    for th in ("light", "dark"):
        cs = [c for c in chrome if c["surface"] == s and c["theme"] == th]
        row.append(f"{round(100 * (1 - sum(1 for c in cs if c['cr'] < need(c)) / len(cs)))}%" if cs else "—")
    L.append(f"| {s} | {row[0]} | {row[1]} | {sum(1 for c in chrome if c['surface'] == s)} |")
L.append("")

L.append("## Small text (under ~10 pt)\n")
L.append("| ~pt | Text | Surface |\n|---|---|---|")
seen = set()
for c in sorted(tiny, key=lambda c: c["pt"]):
    if c["text"] in seen: continue
    seen.add(c["text"])
    L.append(f"| {c['pt']} | {c['text'][:60].replace('|', '/')} | {c['surface']} |")
    if len(seen) >= 25: break
L.append("")

L.append("## Truncation\n")
L.append("| Text | Surfaces |\n|---|---|")
by = {}
for c in trunc:
    by.setdefault(c["text"], set()).add(c["surface"])
for t, ss in sorted(by.items(), key=lambda kv: -len(kv[1]))[:30]:
    L.append(f"| {t[:60].replace('|', '/')} | {', '.join(sorted(ss))[:120]} |")
L.append("")

if static:
    L.append("## Hit targets + font sizes in code (static scan, candidates)\n")
    L.append(f"Scanned `{static.get('src')}` at {static.get('rev', '?')}. A Button/tap gesture whose explicit frame is under 24 pt on a side, "
             "unless a `.contentShape`/padding nearby makes the hit area larger (check by hand).\n")
    L.append("| Size | Where |\n|---|---|")
    for t in static.get("targets", [])[:30]:
        L.append(f"| {t['w']}×{t['h']} | `{t['where']}` |")
    L.append("\n| Font pt | Count | Example |\n|---|---|---|")
    for f in static.get("fonts", []):
        L.append(f"| {f['pt']} | {f['count']} | `{f['example']}` |")
    L.append("")

L.append("## Not captured\n")
for s in skipped:
    L.append(f"- **{s['surface']}** — {s['skipped']}")
for r in shots.values():
    if not r.get("ok"):
        L.append(f"- {r['file']} — {r.get('error', 'failed')}")
L.append("- Pictures show the window as macOS draws it **inactive** (a headless probe is never key): grey traffic lights, "
         "no focus rings. Same for every build, so before/after pairs stay fair.")
open(os.path.join(out, "audit.md"), "w").write("\n".join(L) + "\n")
print(json.dumps(summary))
