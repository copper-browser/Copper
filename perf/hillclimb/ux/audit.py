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

load = lambda name, empty: json.load(open(os.path.join(out, name))) if os.path.exists(os.path.join(out, name)) else empty
rows = load("shots.json", [])  # absent on a keywin-only pack (the mini)
shots = {r["file"]: r for r in rows if r.get("file")}
skipped = [r for r in rows if r.get("skipped")]
keywin = load("keywin.json", None)
WIDTH = {"1440": 1440, "full": 1728, "900": 900, "1100": 1100}  # points across, per size name (drive.py SIZES)
ocr = [json.loads(l) for l in open(os.path.join(out, "ocr.jsonl"))] if os.path.exists(os.path.join(out, "ocr.jsonl")) else []
keys = load("keys.json", [])
static = json.load(open(os.path.join(out, "static.json"))) if os.path.exists(os.path.join(out, "static.json")) else None
run = json.load(open(os.path.join(out, "run.json"))) if os.path.exists(os.path.join(out, "run.json")) else {}

# Calibrate box height → CSS px on the fixture's body paragraphs (17 px).
body = []
for shot in ocr:
    meta = shots.get(shot["file"], {})
    scale = shot["w"] / WIDTH.get(meta.get("size"), 1728)
    for l in shot["lines"]:
        if len(l["t"]) > 40 and norm(l["t"]) in page_text and l["h"] / scale < 30:
            body.append(l["h"] / scale / 17)
factor = statistics.median(body) if len(body) > 5 else 1.15

# The window's own chrome (sidebar, toolbar) is counted on the main-* shots only:
# behind a panel's scrim it is dimmed on purpose, and counting it on every
# surface would weigh the sidebar 40 times over.
frame = {}
is_frame = lambda s: s.startswith("main-") or s in ("narrow-sidebar", "narrow-top")  # the bare window, each layout/size
for shot in ocr:
    meta = shots.get(shot["file"], {})
    if is_frame(meta.get("surface", "")):
        frame.setdefault(meta.get("theme"), set()).update(norm(l["t"]) for l in shot["lines"])

chrome = []
for shot in ocr:
    meta = shots.get(shot["file"], {})
    scale = shot["w"] / WIDTH.get(meta.get("size"), 1728)
    for l in shot["lines"]:
        t = norm(l["t"])
        if len(t) < 2 or l["c"] < 0.5 or (len(t) > 3 and t in page_text):
            continue
        if not is_frame(meta.get("surface", "")) and t in frame.get(meta.get("theme"), ()):
            continue
        pt = l["h"] / scale / factor
        chrome.append({"file": shot["file"], "surface": meta.get("surface", "?"), "theme": meta.get("theme", "?"),
                       "size": meta.get("size", "?"), "text": l["t"], "pt": round(pt, 1), "cr": l["cr"],
                       "fg": l["fg"], "bg": l["bg"], "large": pt >= 18,
                       "trunc": (t.endswith("...") or l["t"].endswith("…")) and t not in PLACEHOLDERS and not MENU.match(t)})
need = lambda c: 3.0 if c["large"] else 4.5
r2 = lambda c: c["surface"].startswith(("narrow-", "welcome-"))
fails = [c for c in chrome if c["cr"] < need(c)]
tiny = [c for c in chrome if c["pt"] < 10]
trunc = [c for c in chrome if c["trunc"]]
kpass = sum(1 for k in keys if k["pass"] is True)
kfail = sum(1 for k in keys if k["pass"] is False)
kna = sum(1 for k in keys if k["pass"] is None)

summary = {
    "shots": len(shots), "shotsFailed": sum(1 for r in shots.values() if not r.get("ok")), "notCaptured": [s["surface"] for s in skipped],
    "chromeLines": len(chrome), "contrastPass": round(100 * (1 - len(fails) / max(1, len(chrome))), 1),
    # R1's surface set only (R2 added narrow-* and welcome-*), so the R1 baseline stays comparable.
    "contrastPassR1": round(100 * (1 - sum(1 for c in fails if not r2(c)) / sum(1 for c in chrome if not r2(c))), 1)
                      if any(not r2(c) for c in chrome) else None,
    "contrastPassByTheme": {th: round(100 * (1 - sum(1 for c in fails if c["theme"] == th) / max(1, sum(1 for c in chrome if c["theme"] == th))), 1) for th in ("light", "dark")},
    "under10pt": len(tiny), "truncatedLines": len(trunc), "truncatedUnique": len({c["text"] for c in trunc}),
    "medianChromePt": round(statistics.median([c["pt"] for c in chrome]), 1) if chrome else None,
    "keys": {"pass": kpass, "fail": kfail, "na": kna}, "calibration": round(factor, 3),
    "load": run.get("load"), "seconds": run.get("seconds"),
}
if static:
    summary["static"] = {k: static[k] for k in ("smallTargets", "smallFonts") if k in static}
if keywin:
    kc = keywin.get("checks", [])
    ax = [a for a in keywin.get("ax", []) if a.get("controls") is not None]
    sw = keywin.get("sweep") or {}
    summary["keywin"] = {"pass": sum(1 for k in kc if k["pass"] is True), "fail": sum(1 for k in kc if k["pass"] is False),
                         "na": sum(1 for k in kc if k["pass"] is None), "key": bool(keywin.get("env", {}).get("key")),
                         "axSurfaces": len(ax), "axUnnamed": sum(len(a["unnamed"]) for a in ax) if ax else None,
                         "settingsControls": sw.get("controls"), "settingsUnnamed": len(sw.get("unnamed", [])) if sw else None,
                         "settingsUnreachable": len(sw.get("unreachable", [])) if sw else None,
                         "motion": {m["name"]: {k: m.get(k) for k in ("frames", "span_ms", "stable_frame", "stable_ms", "moved")}
                                    for m in keywin.get("motion", []) if m.get("frames")}}
json.dump({"summary": summary, "chrome": chrome, "keys": keys}, open(os.path.join(out, "audit.json"), "w"), indent=1)

L = []
L.append(f"# UX audit — {run.get('label', os.path.basename(os.path.dirname(out)))}\n")
L.append(f"{summary['shots']} pictures ({summary['shotsFailed']} failed), {run.get('seconds', '?')} s, load {run.get('load')}, "
         f"{run.get('scale', '?')} picture px per window pt (compare only runs with the same). "
         "Every number below is measured from the pictures (Vision OCR) or the scripted checks; sizes are estimates "
         f"(line box ÷ {factor:.2f}, calibrated on the fixture's 17 px body text).\n")
L.append("| Measure | Value | Bar |\n|---|---|---|")
L.append(f"| Chrome text lines read | {len(chrome)} | — |")
L.append(f"| Contrast ≥ WCAG AA (4.5:1, 3:1 if ≥18 pt) | {summary['contrastPass']}% (light {summary['contrastPassByTheme']['light']}%, dark {summary['contrastPassByTheme']['dark']}%); R1 surfaces only {summary['contrastPassR1']}% | 100% |")
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

def cell(v):
    return str(v).replace("|", "/").replace("\n", " ")[:170]


if not shots:
    L = L[:1]  # a keywin-only pack (the mini) has no pictures to read: only its own sections below
if keywin:
    env, kc = keywin.get("env", {}), keywin.get("checks", [])
    L.append("## B13 Keyboard + VoiceOver (key-window run, mini)\n")
    L.append(f"Windowed probe world, {keywin.get('seconds', '?')} s. Key window: **{env.get('key') or 'none'}** "
             f"(front app {env.get('front')}, screen locked {env.get('screenLocked')}); full keyboard access in the app: "
             f"{env.get('keyboardNavigation')}; AppleActionOnDoubleClick {env.get('AppleActionOnDoubleClick') or 'unset (zoom)'}. "
             f"{summary['keywin']['pass']} pass · {summary['keywin']['fail']} fail · {summary['keywin']['na']} n/a.\n")
    L.append("| | Cat | Check | Detail |\n|---|---|---|---|")
    for k in kc:
        mark = "✅" if k["pass"] is True else ("➖" if k["pass"] is None else "❌")
        L.append(f"| {mark} | {k['category']} | {k['check']} | {cell(k['detail'])} |")
    for wk in keywin.get("walks", []):
        L.append(f"\n**Tab walk — {wk['surface']}**: {wk['distinct']} distinct stops, ring/visible change on {wk['ringed']}/{len(wk['steps'])}\n")
        L.append("| # | Who has the keyboard | AX focus | Ring (edge px moved) | Window px moved |\n|---|---|---|---|---|")
        for st in wk["steps"]:
            f = st.get("focused") or {}
            L.append(f"| {st['step']} | {st.get('firstResponder')} | {f.get('role', '')} {cell(f.get('label') or f.get('title') or '')} | {st.get('ring')} | {st.get('moved')} |")
    L.append("\n**VoiceOver names per surface** (the window's own AX tree, in process)\n")
    L.append("| Surface | AX elements | Controls | Unnamed | Unnamed (role · value · frame) |\n|---|---|---|---|---|")
    none = [a for a in keywin.get("ax", []) if a.get("controls") is None]
    if len(none) == len(keywin.get("ax", [])) and none:
        L.append(f"| all {len(none)} surfaces ({', '.join(a['surface'] for a in none)}) | {none[0].get('elements', '—')} | — | — | {cell(none[0].get('note', ''))} |")
    for a in keywin.get("ax", []) if len(none) < len(keywin.get("ax", [])) else []:
        if a.get("controls") is None:
            L.append(f"| {a['surface']} | {a.get('elements', '—')} | — | — | {cell(a.get('note', ''))} |")
        else:
            which = "; ".join("%s · %s · %s" % (u["role"], u.get("value") or "", u.get("frame")) for u in a["unnamed"][:6])
            L.append(f"| {a['surface']} | {a['elements']} | {a['controls']} | {len(a['unnamed'])} | {cell(which)} |")
    sw = keywin.get("sweep") or {}
    if sw.get("pages"):
        L.append("\n**Settings, every control's own ledger** (`settings ax sweep`: name + keyboard stop as drawn)\n")
        L.append("| Page | Controls | Kinds |\n|---|---|---|")
        for page, v in sw["pages"].items():
            L.append(f"| {page} | {v.get('controls')} | {cell(v.get('kinds'))} |")
        for what in ("unnamed", "unreachable"):
            if sw.get(what):
                L.append(f"\n{what.capitalize()}: " + "; ".join(sw[what][:30]))
    L.append("")
    if keywin.get("motion"):
        L.append("## B14 Motion + interaction states (recordings, mini)\n")
        L.append("`bench window` pictures (WindowServer's pixels, so frames mid-animation are what was on screen) as fast as they come, "
                 "frame 000 before the trigger. *Still from* = the first frame after which every frame matches the last "
                 "(≤ 0.1% of pixels moved by > 6/255). Sheets: `motion/<name>/sheet.png`.\n")
        L.append("| Recording | Frames | Span ms | Still from frame (ms) | Pixels changed overall | Note |\n|---|---|---|---|---|---|")
        for m in keywin["motion"]:
            if m.get("frames") and "span_ms" in m:
                L.append(f"| [{m['name']}](motion/{m['name']}/sheet.png) | {m['frames']} | {m['span_ms']} | {m['stable_frame']} ({m['stable_ms']}) | {m.get('moved')} | {cell(m.get('note', ''))} |")
            elif m.get("frames"):
                L.append(f"| [{m['name']}](motion/{m['name']}/sheet.png) | {m['frames']} | — | — | steps {m.get('steps')} | {cell(m.get('note', ''))} |")
            else:
                L.append(f"| {m['name']} | — | — | — | — | {cell(m.get('note', ''))} |")
        L.append("")

L.append("## Not captured\n")
for s in skipped:
    L.append(f"- **{s['surface']}** — {s['skipped']}")
for r in shots.values():
    if not r.get("ok"):
        L.append(f"- {r['file']} — {r.get('error', 'failed')}")
L.append("- Pictures show the window as macOS draws it **inactive** (a headless probe is never key): grey traffic lights, "
         "no focus rings. Same for every build, so before/after pairs stay fair.")
L.append("- Sheets drawn by `bench canvas picture` have **square corners**; on screen macOS rounds them like the window. "
         "A capture artefact, not the app: don't mark corners down from these pictures.")
open(os.path.join(out, "audit.md"), "w").write("\n".join(L) + "\n")
print(json.dumps(summary))
