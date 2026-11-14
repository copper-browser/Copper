# Track B — UI/UX evidence pack

One command rebuilds the pictures, the audit and the keyboard checks for one Copper build.

```sh
# devbox → laptop (scripts + bench), then run there (Retina, background probe worlds only)
rsync -az ~/src/copper-hc/perf/hillclimb/ personal-laptop:hc/harness/ && rsync -a ~/src/copper-hc/bench personal-laptop:hc/bin/bench
ssh personal-laptop 'cd ~/hc/harness && ./ux.sh LABEL ~/hc/LABEL/Copper.app'        # ~15 min
rsync -a personal-laptop:hc/out/LABEL/ux/ ~/plans/copper-hillclimb-2026-11-14/out/LABEL/ux/
python3 perf/hillclimb/ux/static.py ~/src/copper-hc ~/plans/copper-hillclimb-2026-11-14/out/LABEL/ux   # hit targets/fonts in code (devbox)
python3 perf/hillclimb/ux/audit.py ~/plans/copper-hillclimb-2026-11-14/out/LABEL/ux                   # re-render audit.md with them
perf/hillclimb/ux/before-after.sh base LABEL     # → out/LABEL/before-after/INDEX.md (devbox, ImageMagick)
```

`UX_ONLY=cmdk-sidebar,split-top ./ux.sh LABEL APP` reshoots just those surfaces (no checks, no audit).

## What it does

- `ux.sh` serves `ux/site/` (fixed fixture pages + a 2 MB file) on 127.0.0.1:4149, then `ux/drive.py`:
  - **first-run world** (empty): the window, Move in (a made-up Arc profile, never this Mac's Arc) preview + done, empty History/Downloads/Bookmarks/Passwords.
  - **lived-in world**: 4 spaces (blue/green/teal + an empty one), 3 pins, folders (`Reading`, `Projects › Copper`), 14 tabs asleep on real hosts with icons pre-cached from `ux/seed/icons` (no network for the sidebar), history + bookmarks, the page on screen local.
  - every surface via `bench canvas picture` (the app draws its window + sheets/popovers; `screencapture` fails over ssh and would bring windows forward).
  - keyboard + findability checks → `keys.json`.
- `ux/ocr.swift` (compiled to `~/hc/bin/ux-ocr`): Vision OCR of every picture with ink/ground colour per line.
- `ux/audit.py` → `audit.md` + `audit.json`: WCAG contrast of chrome text (fixture page text is excluded by matching the fixture's words), estimated font size, truncation (`…`), the checks as pass/fail, and `static.json` (hit-target + font-size candidates from the Swift source) when present.

## Names (pair 1:1 across builds)

`<surface>-<theme>-<size>.png`; theme `light|dark`; size `1440` (1440×900) or `full` (1728×1117, the M1 Pro's whole screen in points). Pictures are 2× (Retina).
Surfaces: firstrun-window, movein-preview, movein-done, {history,downloads,bookmarks,passwords}-empty, main-{sidebar,top}, cmdk-{sidebar,top}, cmdk-query-{sidebar,top}, newtab-suggest-{sidebar,top}, split-{sidebar,top}, address-hover, space-work, space-empty, space-page, settings-{general,tabs,spaces,intelligence,agents,cloud,extensions,passwords,privacy,about}, {history,downloads,bookmarks,passwords}-panel, password-offer, update-pill, agent-{empty,chat,driver,pill}, error-refused.

## Before / after

`before-after.sh A B` compares `out/A/ux/shots` with `out/B/ux/shots`, keeps pairs where > 0.05% of pixels moved by > 8% (`UX_DIFF_PCT`, `UX_FUZZ`), and writes side-by-side JPEGs + `INDEX.md` to `out/B/before-after/`. Noise floor: two runs of the same build (see REPORT.md) — if a pair from identical builds shows up, raise `UX_DIFF_PCT` above it.

## Limits (all builds equally, so pairs stay fair)

- The probe window is never key: grey traffic lights, no focus rings on Copper's own controls, inactive selection colours.
- No accessibility tree in a headless probe (`bench ai ax` → one AXGroup) and ssh isn't AX-trusted, so hit targets come from the source scan, not the screen; VoiceOver labels are not measured.
- Onboarding is suppressed in headless worlds; title-bar double-click has no bench verb. Both are proposals in REPORT.md.
- Arc reference: `arc-ref/` + `arc-ref/SOURCES.md` (public images only; Collin's Arc is never opened).
