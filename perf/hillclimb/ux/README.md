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

**Key-window run (B13 keyboard + VoiceOver, B14 motion) — mini only**, one windowed probe world under `lockf ~/hc/mini.lock` (~2 min):

```sh
rsync -az --exclude __pycache__ ~/src/copper-hc/perf/hillclimb/ mac-mini:hc/harness-r2ux/ && rsync -a ~/src/copper-hc/bench mac-mini:hc/harness-r2ux/bench
ssh mac-mini 'cd ~/hc/harness-r2ux && UX_MODE=keywin UX_PORTS=4231-4232 UX_SITE_PORT=4233 UX_BIN=$HOME/hc/harness-r2ux/bin \
  BENCH=$HOME/hc/harness-r2ux/bench UX_OUT=$HOME/hc/harness-r2ux/out/LABEL/ux ./ux.sh LABEL ~/hc/LABEL/Copper.app'
rsync -a mac-mini:hc/harness-r2ux/out/LABEL/ux/{keywin.json,motion.json,keywin,motion} ~/plans/copper-hillclimb-2026-11-14/out/LABEL/ux/
python3 perf/hillclimb/ux/audit.py ~/plans/copper-hillclimb-2026-11-14/out/LABEL/ux   # audit.md gains B13 + B14
```
`UX_PORTS` / `UX_SITE_PORT` / `UX_BIN` / `UX_OUT` keep parallel workers apart (defaults 4140–4148, 4149, `~/hc/bin`, `~/hc/out/LABEL/ux`).

## What it does

- `ux.sh` serves `ux/site/` (fixed fixture pages + a 2 MB file) on 127.0.0.1:4149, then `ux/drive.py`:
  - **first-run world** (empty): the window, Move in (a made-up Arc profile, never this Mac's Arc) preview + done, empty History/Downloads/Bookmarks/Passwords.
  - **lived-in world**: 4 spaces (blue/green/teal + an empty one), 3 pins, folders (`Reading`, `Projects › Copper`), 14 tabs asleep on real hosts with icons pre-cached from `ux/seed/icons` (no network for the sidebar), history + bookmarks, the page on screen local.
  - every surface via `bench canvas picture` (the app draws its window + sheets/popovers; `screencapture` fails over ssh and would bring windows forward).
  - **narrow world**: the lived-in seed + 8 spaces and long tab titles, at 900×700 and 1100×720 (sidebar + top, light + dark).
  - **Welcome**: `bench ui welcome on`, every page by a click on Continue (headless needs the hc/hooks build; else "n/a: hook missing").
  - keyboard + findability checks → `keys.json`.
- `ux/keywin.py` (`UX_MODE=keywin`, mini): a windowed world (LaunchAgent in gui/UID), pictures by `bench window` (WindowServer's pixels).
  - B13 → `keywin.json`: Tab/⇧Tab walks (main, ⌘K, Settings) with who has focus + a ring test (pixels moved on the focused control's edge),
    full keyboard access set and put back; ⎋ in ⌘K (real key + `summon --keys ⎋` hook); title-bar double-click (`mouse double` hook,
    per AppleActionOnDoubleClick); VoiceOver names per surface from the in-process AX tree + `settings ax sweep` (Settings' own ledger);
    Welcome pages in a window.
  - B14 → `motion/<name>/NNN.png` + `sheet.png` (+ mp4 if ffmpeg): space switch, the slide held at 0/¼/½/¾/1, ⌘K open/close,
    split create, tab hover, tab press-and-drag; per recording frames, ms span, frame/ms until still (`motion.json`).
- `ux/pix.swift` (→ `ux-pix`): picture diffs, frame sequences and contact sheets without ImageMagick.
- `ux/ocr.swift` (compiled to `~/hc/bin/ux-ocr`): Vision OCR of every picture with ink/ground colour per line.
- `ux/audit.py` → `audit.md` + `audit.json`: WCAG contrast of chrome text (fixture page text is excluded by matching the fixture's words), estimated font size, truncation (`…`), the checks as pass/fail, and `static.json` (hit-target + font-size candidates from the Swift source) when present.

## Names (pair 1:1 across builds)

`<surface>-<theme>-<size>.png`; theme `light|dark`; size `1440` (1440×900) or `full` (1728×1117, the M1 Pro's whole screen in points). Pictures are 2× (Retina).
Sizes `900` (900×700) and `1100` (1100×720) are the narrow windows.
Surfaces: welcome-{hello,bring,hold,links}, narrow-{sidebar,top}, narrow-cmdk-{sidebar,top}, firstrun-window, movein-preview, movein-done, {history,downloads,bookmarks,passwords}-empty, main-{sidebar,top}, cmdk-{sidebar,top}, cmdk-query-{sidebar,top}, newtab-suggest-{sidebar,top}, split-{sidebar,top}, address-hover, space-work, space-empty, space-page, settings-{general,tabs,spaces,intelligence,agents,cloud,extensions,passwords,privacy,about}, {history,downloads,bookmarks,passwords}-panel, password-offer, update-pill, agent-{empty,chat,driver,pill}, error-refused.

## Before / after

`before-after.sh A B` compares `out/A/ux/shots` with `out/B/ux/shots`, keeps pairs where > 0.05% of pixels moved by > 8% (`UX_DIFF_PCT`, `UX_FUZZ`), and writes side-by-side JPEGs + `INDEX.md` to `out/B/before-after/`. Noise floor: two runs of the same build (see REPORT.md) — if a pair from identical builds shows up, raise `UX_DIFF_PCT` above it.

## Limits (all builds equally, so pairs stay fair)

- No window is ever key while the mini's screen is locked (loginwindow in front; checked each run): focus rings and real ⎋/Tab are then
  "n/a: no key window". The headless laptop probes are never key either: grey traffic lights, inactive selection colours.
- SwiftUI builds no accessibility tree without a real accessibility client (`bench ai ax` → one AXGroup, windowed too), so VoiceOver
  names are measured for Settings only (its control ledger); other surfaces report n/a until a build exposes the tree.
- Welcome (headless) and ⎋ / double-click need the hc/hooks build; on others they read "n/a: hook missing (needs hc/hooks)".
- Laptop pictures depend on its display scaling (`run.json` `scale`: 2.0 at default, lower under "More Space", which thins text ink
  and moves contrast): compare runs with the same scale only.
- Arc reference: `arc-ref/` + `arc-ref/SOURCES.md` (public images only; Collin's Arc is never opened).
