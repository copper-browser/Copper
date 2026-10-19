# canvas-easel — an easel board, and why it was slow to zoom

A real easel board (the atlas collage the `easel` MCP server composes for Copper Cloud):
95 shapes, 76 of them SVG image cards — text cards, public-domain paintings in museum
mats, tone-on-tone section prints — 2.2 MB of ops. `board.json.gz` is that board with
every word swapped for placeholder text by `sanitize.py` (same cards, sizes, filters,
patterns and pictures; nobody's notes). It is the board *before* the easel fixes below,
so it keeps reproducing the problem.

## Run it

Same CLI and probe-world rules as `../canvas-big` (never port 4123):

```sh
export SEARCH_PROBE=easel SEARCH_MCP_PORT=4205 COPPER_BIN=<build>/Copper.app/Contents/Resources/bin/copper
../canvas-big/launchd-probe.sh start <build>/Copper.app easel 4205     # or open -n … like canvas-big
python3 bench.py apply "Easel bench"                 # → {"id": …}
python3 bench.py measure <id> section 4              # medians of 4 runs of ../canvas-big/measure.js
```

`measure.js` now also reports `run.phases` — frame times for the pan half and the zoom half of
its path — and `bench.py` prints their medians.

**Measure at 2×.** A headless probe on a Mac mini without a display renders at
`devicePixelRatio` 1 and this board looks fine there (59 fps). On a Retina laptop (the same
headless probe, dpr 2) it is the board people complained about. Numbers below: MacBook Pro
M1 Pro, macOS 26.6, headless probe, dpr 2, bench view z ≈ 0.44, 3–4 runs each.

## What it found

Medians; "zoom" is the second half of measure.js's path (4× out and back in), where all the
cost was — panning was already at 60 fps (p95 17–18 ms) on every build.

| build · board | fps | p95 | zoom p50 / p95 | worst frame | frames > 33 ms |
|---|---:|---:|---:|---:|---:|
| `fork` · this board | 38.5 | 84 | 42 / 127 | 165 | 41 |
| `fork` · same board from the fixed easel (no noise filters, no board/section prints) | 42.7 | 63 | 28 / 92 | 114 | 22 |
| this branch · this board | 49.2 | 34 | 24 / 45 | 84 | 14 |
| this branch · fixed-easel board | **53.7** | **30** | **18 / 38** | 76 | 9 |
| `fork` · this board with every image a 1 px PNG | 51.7 | 25 | 18 / 61 | 78 | 10 |
| this branch · 1 px images | 55.2 | 25 | 19 / 29 | 39 | 2 |

How the time was found (per-frame logs with a MutationObserver: slow zoom frames made no DOM
changes and ran ≈ 0 ms of script — they were paint):

1. **SVG cards are repainted from scratch at every new scale.** WebKit re-rasterizes the board's
   layer each time a zoom changes its scale (and at the promote/demote around every gesture), and
   an `<img>` of an SVG is redrawn from its vector source each time: text, patterns, filters,
   embedded pictures. → Vector images draw from a bitmap copy at the size they are shown
   (`lod.ts` `VECTOR_BUCKETS`, ≈ √2 steps; `thumbs.ts`), made only while the view is still,
   re-made at the right size after a zoom, capped at 16 MP (a backdrop many screens big stays a
   soft bitmap rather than megapixels of vector).
2. **Blurred box-shadows are re-blurred at every new scale.** Blank image cards still stuttered;
   without their shadows they didn't. → `--shadow-note` is drawn from a nine-slice bitmap made at
   startup (`shadows.ts`, light and dark, radii 4/6/12) on `::before`; stickies, image cards,
   checklists and timelines wear it. Falls back to the box-shadow if the bitmaps can't be made.
   Image cards keep the shadow at every zoom now (dropping it far out swapped 48 cards' paint in
   one frame).
3. **Every bitmap is redrawn on the CPU at every new scale.** → Card-sized image elements
   (≤ 2 M world px²) get `will-change: transform`, so WebKit gives them to Core Animation as
   textures and the GPU scales them: zoom frames 29.5 → 17 ms median on the fixed-easel board.

The easel side (grunts-dev/easel `f19a8e5`): paper grain from a 96 px bitmap tile instead of
feTurbulence, the stamp's worn ink a mask instead of turbulence + displacement, board and
section prints opt-in.

`canvas-big` on the same laptop (bench view, 3 runs, its six live local pages dominate):
`fork` 16.7 fps / p50 61 / p95 175 ms → this branch 21.7 fps / p50 18 / p95 143 ms. (On
`devicePixelRatio` 2 that board is far slower than the 42 fps BASELINE.md measured on the mini
at 1×.)
