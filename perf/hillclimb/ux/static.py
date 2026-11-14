#!/usr/bin/env python3
"""Hit-target and font-size candidates read from Copper's Swift source, for
the audit (a headless probe has no accessibility tree to measure from).

    python3 static.py SRC OUTDIR      → OUTDIR/static.json (then rerun audit.py)

A target candidate: a `.frame(width: W, height: H)` (numbers) within 10 lines
after a Button / onTapGesture / Toggle, with min(W, H) < 24 and no
`.contentShape` or `.padding` in the next 4 lines. Candidates, not verdicts.
"""
import collections, json, os, re, subprocess, sys

src, out = sys.argv[1], sys.argv[2]
FRAME = re.compile(r"\.frame\(\s*width:\s*([0-9.]+)\s*,\s*height:\s*([0-9.]+)\s*\)")
FONT = re.compile(r"\.font\(\.system\(size:\s*([0-9.]+)")
TAP = re.compile(r"\bButton\s*[({]|\.onTapGesture|\bToggle\s*\(")
targets, fonts = [], collections.defaultdict(list)
root = os.path.join(src, "Sources", "Search")
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".swift") or "Bench" in f or "Test" in f:
            continue
        path = os.path.join(dirpath, f)
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        rel = os.path.relpath(path, src)
        for i, line in enumerate(lines):
            for m in FONT.finditer(line):
                fonts[float(m.group(1))].append(f"{rel}:{i + 1}")
            m = FRAME.search(line)
            if not m:
                continue
            w, h = float(m.group(1)), float(m.group(2))
            if min(w, h) >= 24 or not any(TAP.search(l) for l in lines[max(0, i - 10):i + 1]):
                continue
            if any(".contentShape" in l or ".padding" in l for l in lines[i + 1:i + 5]):
                continue
            targets.append({"w": w, "h": h, "where": f"{rel}:{i + 1}"})
rev = subprocess.run(["git", "-C", src, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
small = sorted(pt for pt in fonts if pt < 11)
json.dump({"src": src, "rev": rev, "smallTargets": len(targets), "targets": sorted(targets, key=lambda t: min(t["w"], t["h"])),
           "smallFonts": sum(len(fonts[pt]) for pt in small),
           "fonts": [{"pt": pt, "count": len(fonts[pt]), "example": fonts[pt][0]} for pt in sorted(fonts)]},
          open(os.path.join(out, "static.json"), "w"), indent=1)
print(f"{len(targets)} small-target candidates, {sum(len(fonts[pt]) for pt in small)} font uses under 11 pt")
