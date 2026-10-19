# canvas-big — the big-canvas fixture and bench

A reproducible, busy whiteboard for Copper's canvas performance work (contract §D,
`exowatt/reports/2026-10-16-copper-canvas-perf/CONTRACT.md`), and a bench that measures it.
Same fixture, same numbers on macOS Copper and Copper for Linux: both run the one canvas page
([canvas-app](https://github.com/copper-browser/canvas-app) → `canvas.html`) and both speak `copper call` / `copper eval` / `copper shot`.

**Only ever against a probe world.** `apply.sh` and `measure.sh` refuse to run unless
`SEARCH_PROBE` is set and `SEARCH_MCP_PORT` is not 4123 (and, on Linux, `COPPER_WORLD` is set).

## What it builds

`gen.py --scale big` (default seed 20261016, deterministic) → about **1,500 shapes**:

| | big | huge | small |
|---|---:|---:|---:|
| slide frames (1280×720, grid, content inside; every 9th has a photo backdrop) | 40 | 100 | 8 |
| live web frames (960×640): local pages + public sites | 40 (34 + 6) | 100 (94 + 6) | 8 (6 + 2) |
| link cards | 50 | 130 | 10 |
| images (data: URLs, JPEG photos / PNG screenshots / PNG charts, 480–2400 px, ≤ 110 KB each) | 150 | 400 | 30 |
| stickies + text | 900 | 2,450 | 180 |
| checklists (to-do and RSVP, picks, notes) | 60 | 160 | 12 |
| timelines | 10 | 27 | 2 |
| arrows (slide chain, cluster flows, cross-region, some labelled) | 250 | 667 | 50 |
| **shapes** | **1,500** | **≈ 4,000** | **300** |
| comment threads (+ replies, ~25 % resolved) | 40 | 100 | 8 |

Regions: the **deck** (slide grid, top left), the **research wall** of live frames under it,
**brainstorm** sticky clusters to the right, an image **moodboard** under those, and
**planning** (timelines, checklists, cards) at the bottom. About 21,000 × 20,000 board units.

Live frames: local pages from `serve.sh` with real weight — an animated `<canvas>` particle
field (rAF), a 1,500–3,500-row table with a ticking clock, an image gallery of 100 KB–2.3 MB
JPEG/PNG files, a dashboard of CSS animations + SVG sparklines updating twice a second, and a
long design doc; all use web fonts copied from the machine's own fonts (no network) — plus
`example.com`, Wikipedia (*Whiteboard*), MDN (*Canvas API*), w3.org, rust-lang.org and Hacker News.

Why board images are data URLs: the page accepts only `data:` or `https:` image sources
(canvas-app `src/ops.ts` `validImageSrc`), so `http://127.0.0.1` images are not an option; the
heavy served images live inside the local pages instead. Each image op stays under 110 KB so it
fits one argv string on Linux (`MAX_ARG_STRLEN` = 128 KB); `drive.py` splits every
`canvas_apply` JSON into ≤ 100 KB argv pieces at op boundaries (the CLI joins its arguments
with spaces, which JSON ignores), and batches stay ≤ 200 ops and ≤ 600 KB (macOS `ARG_MAX`
is 1 MB including the environment).

## Files

| file | |
|---|---|
| `gen.py` | the generator (Python 3.9+, stdlib only). `--scale small\|big\|huge`, `--seed`, `--base` (default `http://127.0.0.1:8765`), `--out` (default `./out`), `--www-only` |
| `serve.sh` | `python3 -m http.server` on 127.0.0.1:8765 for `out/www` (`fg` / `start` / `stop` / `status`) |
| `apply.sh` | `apply.sh NAME [scale]`: create, open in front, apply every batch (timed), focus the bench view, read back |
| `measure.js` | a function for `copper eval`: DOM nodes, mounted shapes, live iframes, images, scripted 5 s pan+zoom rAF p50/p95 |
| `measure.sh` | runs `measure.js` two-phase, adds the probe's own WebContent/GPU/Networking RSS (macOS), optional `--shot /tmp/…` |
| `drive.py`, `_guard.sh` | what the two wrappers run |
| `launchd-probe.sh` | start/stop a headless probe as a launchd job (for ssh sessions: the Mac mini) |
| `BASELINE.md` | the BEFORE numbers on unmodified `fork`, Mac mini (M6), plus MCP observations |
| `out/` | generated, git-ignored: `out/<scale>/ops-NNN.json`, `manifest.json`, `apply-*.json` reports, `out/www/` |

`manifest.json` has the expected counts, `focusIds` (three live frames of the wall's first row and
the slide above them — the bench view, z ≈ 0.44 on a 1440 px board), the batch list and the board's bounds.

## macOS (probe)

```sh
cd <repo>       # e.g. ~/src/copper-canvasperf
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh
F=docs/fixtures/canvas-big
python3 $F/gen.py --scale big                     # ~45 s the first time (images + pages)
$F/serve.sh start                                 # http://127.0.0.1:8765/
open -n -g --stderr /tmp/copper-cfix.log --env SEARCH_PROBE=cfix --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT=4203 --env SEARCH_HEADLESS_SIZE=1840x1240 build/Copper.app
export SEARCH_PROBE=cfix SEARCH_MCP_PORT=4203
C=build/Copper.app/Contents/Resources/bin/copper
until $C health >/dev/null 2>&1; do sleep 1; done
$F/apply.sh "Canvas big" big                      # per-batch timings, final read-back count
sleep 20                                          # let frames and images load
$F/measure.sh --shot /tmp/canvas-big.png          # JSON: before / run (p50, p95…) / after / webContent
$C eval "$(cat $F/measure.js)"                    # or by hand: starts a run …
sleep 7; $C eval "$(cat $F/measure.js)"           # … and reads it
kill $(lsof -tiTCP:4203 -sTCP:LISTEN)             # ONLY the probe's pid; never pkill Copper
$F/serve.sh stop
```

`COPPER_BIN` overrides the CLI path (default: `<repo>/build/Copper.app/Contents/Resources/bin/copper`,
then `copper` on PATH). Re-running `apply.sh` with a new NAME builds another copy; the probe world's
data lives in `~/Library/Application Support/Copper (cfix)/` — delete that folder for a clean slate
(never the plain `Copper/` folder, which is the everyday browser's).

WebContent RSS: `measure.sh` asks launchd which WebKit processes belong to the probe
(`launchctl print pid/<pid listening on SEARCH_MCP_PORT>` lists the app's WebContent, GPU and
Networking service instances with their pids) and reports their RSS plus the app's own — exact even
with other Coppers running. Only if that fails does it fall back to WebContent processes started
after `FIXTURE_PROBE_STARTED`.

**Screenshots go to `/tmp`.** The probe writes the file itself, on its main thread; a path the app
may not write without a privacy prompt (an external volume, `~/Desktop`, `~/Documents`) blocks the
main thread in `open()` and with it the whole MCP server (see BASELINE.md).

## Mac mini (the reference machine for before/after numbers)

`BASELINE.md` numbers come from Felipe's Mac mini (M6); re-measure there to compare. From a bare
`ssh` session `open` fails (`-10810`) and `launchctl asuser` is not permitted, so the probe runs as a
launchd job in the GUI session: `launchd-probe.sh` writes the plist and boots it (logs in `/tmp` — a
log path on `/Volumes/…` makes launchd fail the job with `EX_CONFIG`).

```sh
M=felipearce@100.112.175.26; W=/Volumes/Farm/farm/fixture
git -C ~/src/copper-jev archive origin/fork | ssh -o BatchMode=yes $M "mkdir -p $W/base && tar xf - -C $W/base"
tar czf - --exclude=out -C ~/src/copper-canvasperf/docs/fixtures/canvas-big . | ssh -o BatchMode=yes $M "mkdir -p $W/src && tar xzf - -C $W/src"
ssh -o BatchMode=yes $M
  export PATH=/opt/homebrew/bin:$PATH W=/Volumes/Farm/farm/fixture
  (cd $W/base && SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=- ./build.sh)
  cd $W/src && python3 gen.py --scale big && ./serve.sh start
  ./launchd-probe.sh start $W/base/build/Copper.app cfix 4203
  export SEARCH_PROBE=cfix SEARCH_MCP_PORT=4203 COPPER_BIN=$W/base/build/Copper.app/Contents/Resources/bin/copper
  until $COPPER_BIN health >/dev/null 2>&1; do sleep 0.5; done
  ./apply.sh "Canvas big" big                       # once; the board persists in the cfix world
  # the measured protocol (BASELINE.md): relaunch, bench view, 3 runs, overview, 1 run
  ./launchd-probe.sh start $W/base/build/Copper.app cfix 4203      # relaunch (bootout + bootstrap)
  until $COPPER_BIN health >/dev/null 2>&1; do sleep 0.25; done
  ID=<canvas id from apply.sh>
  $COPPER_BIN call canvas_focus "{\"id\":\"$ID\",\"shapeIds\":$(python3 -c 'import json;print(json.dumps(json.load(open("out/big/manifest.json"))["focusIds"]))')}"
  sleep 20; for n in 1 2 3; do ./measure.sh > /tmp/bench-$n.json; sleep 3; done
  $COPPER_BIN shot /tmp/bench-view.png
  # overview: focus the leftmost/rightmost/topmost/bottommost shapes (from canvas_read), sleep 15, ./measure.sh
  ./launchd-probe.sh stop cfix          # stops ONLY this probe; never touch ~/.grunts/Copper.app
  ./serve.sh stop
exit
ssh -o BatchMode=yes $M "rm -rf $W"                     # when done (copy evidence back first)
```

## Linux (devbox)

The Linux CLI has the same `call` / `eval` / `shot` / `health` commands and honours
`SEARCH_MCP_PORT`; the world is chosen by `COPPER_WORLD` (default world = Felipe's real profile —
**always** set it).

```sh
# on the Mac: build (bin/dbx rsyncs the tree)
cd ~/src/copper-linux && bin/dbx cargo build --release -p copper-app
# copy the fixture over (python3 is on the devbox; gen.py output is identical for the same seed)
rsync -a ~/src/copper-canvasperf/docs/fixtures/canvas-big/ devbox:copper-canvas-big/ --exclude out/
ssh devbox
  # in the dbx/QA session env (WAYLAND_DISPLAY, XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS — see bin/dbx
  # or ~/copper-qa/env.sh); then:
  export COPPER_WORLD=cfix SEARCH_PROBE=cfix SEARCH_MCP_PORT=4203
  export COPPER_BIN=$HOME/src/copper-linux/target/release/copper
  mkdir -p ~/.local/share/copper-cfix && [ -f ~/.local/share/copper-cfix/agent.json ] || \
    (printf '{"enabled":true,"port":4203,"jev":false}\n' > ~/.local/share/copper-cfix/agent.json; chmod 600 ~/.local/share/copper-cfix/agent.json)
  cd ~/copper-canvas-big
  python3 gen.py --scale big && ./serve.sh start
  setsid "$COPPER_BIN" </dev/null >/tmp/copper-cfix.log 2>&1 &
  until "$COPPER_BIN" health >/dev/null 2>&1; do sleep 1; done
  ./apply.sh "Canvas big" big
  sleep 20; ./measure.sh --shot /tmp/canvas-big.png
  kill $(ss -ltnp 'sport = :4203' | grep -o 'pid=[0-9]*' | cut -d= -f2)   # only that copper
  ./serve.sh stop
```

On Linux `measure.sh` reports no WebContent RSS; use
`ps -o pid,rss,cmd --ppid $(pgrep -f "copper-cfix" | head -1)` or `smem` for the WebKitWebProcess children.

## What measure.js reports

```jsonc
{ "state": "done",
  "before": { "domNodes", "mountedShapes", "mountedByKind", "iframes", "liveIframes", "images", "imagesLoaded",
              "imagePixelsMP", "svgPaths", "viewport", "view": {x, y, z}, "pageAgeMs", "jsHeapMB"? },
  "run":    { "durationMs", "zoomOut", "frames", "fps", "p50", "p95", "p99", "max", "over25", "over33", "over100",
              "peakDomElements", "peakMountedElements", "peakLiveIframes" },
  "after":  { …same as before, sampled 1.2 s after the motion stops… },
  "webContent": { "processes", "totalMB", "appMB", "gpuMB", "networkMB", "top": [{pid, kind, rssMB}], "filter" } }   // measure.sh
```

- `mountedShapes` = distinct `data-id` values under the board (`[role="application"]`); every shape
  component in canvas-app `src/canvas/components/` carries `data-id={shape.id}`.
- `liveIframes` = `<iframe>` with a real `src`.
- The run: synthetic `wheel` events on the board, driven by time, not frames (each frame sends what
  is still owed of an eased path), so every build travels the same path and ends where it started:
  0–1.25 s pan 1600 px right, 1.25–2.5 s back, 2.5–3.75 s zoom out about the centre (4×, less if
  that would hit `MIN_ZOOM` 0.1 — `run.zoomOut` says how much), 3.75–5 s back in. Frame times are
  rAF-to-rAF. Run it from the bench view (`apply.sh` ends with `canvas_focus` on `focusIds`) after
  the page has settled (≈ 20 s) so before/after runs compare.
- Two-phase because macOS `copper eval` (`evaluateJavaScript`) does not wait for promises.
- Time to `ready` is a host-side number (the page cannot see when the host got `ready`); measure
  it with the host's own logging.
