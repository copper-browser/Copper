# canvas-big — BEFORE baseline (unmodified `fork`), on a reference Mac (M6)

**Machine:** an Apple M6 Mac (12 cores, 24 GB, macOS 27.0, arm64), driven over ssh.
**Build:** clean `git archive origin/fork` at `1de2b6a` (Merge PR #62), `./build.sh` with the
MacOSX26.5 CLT SDK, ad-hoc signed → `Copper.app` 1.0 build 202610161525, `com.collinrijock.copper.dev`.
No canvas-perf changes. **Probe:** world `cfix`, MCP port 4203, `SEARCH_HEADLESS=1`,
`SEARCH_HEADLESS_SIZE=1840x1240` (the board's viewport is 1439×1188 CSS px), started by a launchd
job in the GUI session (see README › Reference machine). **Fixture:** `gen.py --scale big`, seed 20261016
(ops sha of the 17 batches identical on Python 3.9 and 3.14), pages served by `serve.sh` on 127.0.0.1:8765.
Date: 2026-10-16. Measured with `measure.sh` (measure.js + the probe's own WebKit processes from
`launchctl print pid/<app>`).

Re-measure on the same machine with the same protocol to compare (README › Reference machine; `baseline.sh` steps):
relaunch the probe with the board already saved, `canvas_focus` the manifest's `focusIds`, wait
20 s, three `measure.sh` runs; then `canvas_focus` the board's extremes (overview, min zoom),
wait 15 s, one run.

## Board built

| | |
|---|---|
| shapes | **1,500** = 40 slide frames, 40 live web frames (34 local + 6 public), 50 link cards, 150 images, 803 stickies, 97 text, 60 checklists, 10 timelines, 250 arrows |
| comments | 40 threads (+ replies, some resolved) |
| `canvas_apply` | 1,593 ops in 17 batches (≤ 200 ops, ≤ 594 KB each), **1.34 s total**, slowest batch 0.11 s, 0 errors |
| `canvas_read` (tab open) | 0.05 s, 308 KB, 1,500 shapes, 40 threads, no paging (`total` absent: not implemented yet) |
| huge (`--scale huge`, same probe) | 4,034 shapes / 4,314 ops in 45 batches, **4.36 s total**, slowest 0.24 s, 0 errors; read 0.11 s, **834 KB** |

## Bench view (the manifest's `focusIds`: three live frames + the slide above) — z = 0.441

Three runs; median (range).

| metric | before (sample) | 5 s pan + zoom (1600 px right/back, 4× out/in) | after (+1.2 s) |
|---|---|---|---|
| DOM elements | 1,021 | peak **4,282** (3,935–4,318) | 1,021 |
| mounted shapes (distinct `data-id`) of 1,500 | **74** | peak **372** (343–379) | 74 |
| live iframes (`iframe[src]`) | **6** (of 40; the current 6-frame budget, ≥ 260 px) | peak 6 | 6 |
| `<img>` | 6 (3.9 MP natural) | | 6 |
| rAF frame time p50 | | **17 ms** (17 / 17 / 17) | |
| p95 | | **68 ms** (66 / 69 / 68) | |
| p99 / max | | **162 ms** / **195 ms** (187–237) | |
| frames / fps | | 210 / **41.9 fps** (41.5–42.5) | |
| frames > 33 ms / > 100 ms | | **20** (19–21) / **6** (5–7) | |
| WebContent RSS (1 process) | | | **735 MB** (682 → 735 → 775, rising run over run) |
| GPU process / Networking / app | | | 159–179 MB / 29–31 MB / 118–122 MB |

## Overview — min zoom z = 0.100 (focus on the board's extremes; board is wider than the screen even here)

| metric | before | 5 s pan (zoom out skipped: already at MIN_ZOOM) | after |
|---|---|---|---|
| DOM elements | **20,039** | peak 20,039 | 20,039 |
| mounted shapes | **1,298** of 1,500 (208 arrows, 691 stickies, 130 images, 88 links, 59 checklists, 32 frames, 10 timelines, 80 text) | peak 1,382 | 1,298 |
| live iframes | 0 (frames too small → placeholders) | 0 | 0 |
| `<img>` | **138**, all loaded, **165 MP** of natural pixels decoded for ~10 px-wide thumbnails | | |
| SVG paths/lines | 4,539 | | |
| rAF p50 / p95 / p99 / max | | **17 / 158 / 374 / 405 ms** | |
| fps, > 33 ms, > 100 ms | | **26.9 fps**, 23, 10 | |
| WebContent RSS | | | **1,068 MB**; GPU process **736 MB**; app 130 MB |

What it says about today's code: culling already exists at normal zoom (74 of 1,500 mounted) and live
frames are capped at 6, but the zoomed-out view mounts 87 % of the board and decodes every image at
full resolution (165 MP, GPU process 736 MB); motion while zooming out costs p95 66–69 ms at the
bench view and 158 ms at the overview; WebContent memory climbs with each pan/zoom cycle.

## MCP / CLI behaviour while building and reading (evidence for the MCP worker)

Nothing in `canvas_create` / `canvas_apply` / `canvas_read` / `canvas_focus` / `canvas_screenshot`
failed on this machine:

| case | result |
|---|---|
| apply 17 batches (big), 45 batches (huge), tab open in front | 0 errors, ≤ 0.24 s per call |
| cold `canvas_read` right after app launch (tab restored from session) | big 0.90 s, 1.12 s (two launches); huge 1.60 s (835 KB); big as a background tab 1.46 s |
| `canvas_read` with the canvas tab closed | big 0.44 s; huge 0.97 s |
| parallel, tab closed: `canvas_read` + `canvas_screenshot` + `canvas_focus` (big) | all rc 0, 0.42–0.47 s |
| parallel, tab closed: `canvas_read` huge + `canvas_apply` huge + `canvas_read` big | all rc 0, 0.69–0.97 s |

So the "fails if the canvas doesn't load within about a second" report did not reproduce on the
M6 with the unmodified build — cold reads land at 0.9–1.6 s, i.e. right at that boundary; a slower
or busier Mac (the laptop) is the likelier place to see it.

Two real problems hit, both worth fixing:

1. **One blocked tool call freezes the whole MCP server.** `copper shot <path on /Volumes/…>` from
   a launchd-started probe: `browser_take_screenshot` writes the file with `Data.write` **on the
   main thread** (`Tools.dispatch`, Tools.swift:399 → `open()`), and `open()` on an external volume
   blocked on a TCC check nobody could answer. The CLI gave up after 60 s
   (`drive: CLI timed out after 60s`); every later call, even `/health`, then failed with
   `copper: Copper isn't running (or Settings › Agents is off). Start it with \`open -a Copper\`, or pass --launch.`
   (`curl -m 20 /health` → no answer in 20 s; app at 0 % CPU). The main thread's stack (`sample`)
   was `MCP.route → MCP.handle → Tools.call → Tools.pinnedCall → Tools.dispatch → Data.write(to:) → open`.
   Any slow file write or synchronous wait on the main actor takes MCP down with it.
2. **`canvas_apply` checklist with two rows of the same label** fails the op:
   ``picks`: more than one row is called "Localize the changelog" — use its id`` (a fixture bug,
   fixed in gen.py; noted because the row is added but the whole op fails on `picks`).

Also seen: after `launchctl bootout` of the probe, its six frame-site WebContent processes from the
previous instance lingered for minutes (pids 15778–15790), and the first measure run on a board
that had just been built (laptop-style "build then measure" without the relaunch) gave p95 236 ms /
18.5 fps from an older, unanchored pan script — the protocol above (relaunch, focus, wait 20 s)
is what makes runs repeat.

Raw evidence (JSON per run, screenshots, apply reports, the hang sample):
`/Users/felipearce/exowatt/reports/2026-10-16-copper-canvas-perf/fixture/`.
