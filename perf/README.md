# perf — timing Copper the same way before and after a change

Everything here drives a **probe world** (`SEARCH_PROBE=perf SEARCH_MEASURE=1`, "Copper (perf)") through its bench socket, so the browser you use is never touched. `perf.py seed perf` copies the installed Copper's session, history, groups, bookmarks, icons, themes and canvases into that world (read only; never cookies, passwords, Bitwarden or agent keys) and points the restored tab at a local page, so a launch measures the browser rather than a site's servers.

What it reads is `./bench pace` (`Sources/Search/Fork/Pace.swift`):

- **marks**, ms since the kernel started the process: `init`, `window` (root view on screen), `bench`, and the first page's `page.ask` (navigation policy asked, the request about to go out), `page.commit`, `page.paint` (WebKit's first visually non-empty layout) and `page.finish`; `settled` once the launch has let the deferred work go (`Fork/Launch.swift`).
- **the main thread** since `./bench pace reset`: `busy` (summed run-loop passes), `longest`, every pass over 16 ms; `launchSlow`/`launchBusy` for the first 20 s.

## Run it

On the Mac, from a build of the branch (`./build.sh`) and a build of what it is compared with:

```sh
perf/suite.sh base  /path/to/base/build/Copper.app
perf/suite.sh new   build/Copper.app
python3 perf/compare.py base new

# launches only, alternating builds so both see the same machine; FG=1 opens them in front
FG=1 python3 perf/perf.py ablaunch perf base=/path/to/base/Copper.app new=build/Copper.app 6 > ab.txt
python3 perf/abreport.py ab.txt
```

`rawload.swift` is the control: a bare `WKWebView` opening one URL N times in fresh views (`--fresh` clears its store first), printing the same Navigation Timing numbers. Wrap it in an `.app` and start it with `open -W -n -g RawLoad.app --stdout out.txt --args URL N` so it gets a window server. If Copper is far behind it on the same page, the difference is Copper's.

Keep builds and measurements apart — a `swift build` running beside a measurement made bare WebKit look 3× slower. Background launches (`open -g`, the default) put the window behind whatever is in front, where WebKit treats the page as hidden; compare launch times from `FG=1` runs.

## What it found (October 2026, M5 Max, a copy of a real 6-space, 264-tab session)

Medians, `origin/fork` 7c2038f + `Pace` against the perf branch, same suite, back to back:

| | before | after |
|---|---|---|
| restored page painted, foreground launch (local page) | 459 ms | 423 ms |
| main-thread time, first 20 s of a launch | 450 ms | 353–367 ms |
| first switches after launch landing on a page still loading | 5 of 6 | 1 of 6 (a site that never stops loading) |
| ⌘R, first paint — lightspeed.exowatt.com (over the VPN; noisy) | 488 ms (342–1302) | 255 ms (180–668) |
| ⌘R, first paint — GitHub repository page | 672 ms (244–1720) | 341 ms (163–456) |
| main-thread time during one page load (⌘T → address → Return) | 456–511 ms | 407–448 ms |

Restored tabs (`perf.py seed` with `PERF_ACTIVE=URL`, the tab's own Navigation Timing, 4 launches each, base vs the cache-first branch): lightspeed.exowatt.com document 447–691 ms from the network → 4–6 ms from the cache, first paint 767–1141 → 113–163 ms; GitHub repository page document 739–1255 → 10–12 ms, first paint 719–1332 → 212–259 ms.

An animated space froze every launch for 5–6 s on 13 October (base, branch and the installed release alike): `sample` put the main thread in `WebPageProxy::maybeInitializeSandboxExtensionHandle` → `_sandbox_extension_issue` for the backdrop's file URL. With the scene served from `copper-scene://`, no launch pass over 200 ms after the first.

Where a launch's time goes now (warm, ms from process start): AppKit and SwiftUI up to `Browser.init` ~75, WebKit's first use and the files ~45, the restore of 264 tabs ~45, the first web view built and its process launched ~60, the scene to the first body ~60, the first layout ~55, the first frame committed ~45. The restored page's request waits for the end of that first run-loop pass (`page.ask`), because WebKit asks the navigation delegate on the main thread.

A space switch costs ~100 ms of main-thread time, nearly all SwiftUI making the ~44 new rows of the column it lands on (row bodies themselves are cheap; the 158-row space costs ~10 ms more to lay out than a 12-row one). The menu bar's rebuilds were ~1 ms.

## Next, if more is wanted

- Keep each visited space's column mounted and switch which one shows, instead of building its rows on every switch.
- Answer WebKit's first navigation policy before the first frame (the restored page's request goes out when the launch's first run-loop pass ends, ~350 ms).
- Read favicons for tabs not in the current space after the launch rather than during the restore.

## The Wikipedia game: what Jev sees (October 2026)

`perf/wikigame.py` plays ten Wikipedia games (start article → target article, links only, no search) through `jev_run` on a running Copper, one arm per way of seeing the page — `off` (the element table and visible text, the original loop), `screenshot` (plus a JPEG of the viewport in the state), `marks` (the JPEG with every element's index drawn on it) and `box` (the JPEG, and Jev 1.14's Box question pointing at the target instead of an indexed choice) — alternating arms within each game. It reads the world's `agent.json` for the port and token, opens a tab of its own per run and closes it after, and writes one JSON line per run plus a Markdown table of per-arm pass rates, medians and token counts.

```sh
# the installed Copper (Jev mode on, a Jev key set)
python3 perf/wikigame.py --arms off,screenshot,marks,box:jev-1.14.0 --rounds 2
# a build of the branch, headless in its own world on another port
SEARCH_HEADLESS=1 SEARCH_MCP_PORT=4124 build/Copper.app/Contents/MacOS/Copper --headless &
python3 perf/wikigame.py --world "Copper (dev)" --port 4124 --games 1-5 --arms off,off:jev-1.14.0,marks
python3 perf/wikigame.py --summary perf/results/wikigame.jsonl
```

A pass is Jev's DONE on the target article with no TYPE_TEXT along the way. `wall_ms` is `jev_run`'s own clock (first decision to the end, loading included; the initial navigation is outside it), `jev_ms` and tokens are Jev's, summed over the steps. Pictures are a TypeSafe preview (`TypeSafe-Danger-Zone-Images`), so numbers will move as their models do.

### What it found (2026-10-16, a headless dev build on an M6 Mac, 120 runs)

| Arm | Model | Pass | Median wall (passes) | Jev ms / decision p50 | Tokens / decision |
|---|---|---:|---:|---:|---:|
| `off` | jev-1.13.0 | 17/20 | 1,978 ms | 193 | 5,659 |
| `off` | jev-1.14.0 | 18/20 | 2,072 ms | 170 | 5,502 |
| `screenshot` | jev-1.13.0 | 17/20 | 2,609 ms | 352 | 7,796 |
| `marks` | jev-1.13.0 | 18/20 | 2,825 ms | 400 | 7,757 |
| `marks` | jev-1.14.0 | 16/20 | 3,068 ms | 340 | 7,832 |
| `box` | jev-1.14.0 | 14/20 | 3,288 ms | 321 | 5,134 |

Text only is the fastest and as reliable as any picture mode; a picture costs about 2,200 tokens and 160–210 ms more per decision; every box landed on an element (22/22) but the box arm ended BLOCKED most often and was slowest. Full read: `docs/plans/2026-10-16-jev-vision.md`; runs: `perf/results/wikigame.jsonl`.

## The UI bench: the fastest way to run Jev (October 2026)

`perf/uibench.py` drives a made-up admin app (`perf/uibench/app.html`, served by `perf/uibench/server.py` on :8777) through `jev_run`: sign in, settings, a modal with a custom listbox, a wizard, a table of identical buttons, icon-only buttons, and two click drills for actions per minute. The app's own server records what happened, so a pass is the app's verdict. Arms are named presets of `strategy` / `vision` / `model` (see the file); `default` sends nothing, so it measures whatever this Copper ships.

```sh
python3 perf/uibench/server.py &
python3 perf/uibench.py --world "Copper (dev)" --port 4124 --arms classic,turbo,hybrid,default --rounds 3
python3 perf/uibench.py --summary perf/results/uibench-hybrid.jsonl
```

The shipped default (Fast mode + Auto vision) passed 24/24 at 1.9 s a task median and ~145 actions a minute; the original loop passed 15/24 at 4.3 s and ~93. Text-only turbo is fastest where every control has a name and fails where none does; the numbered picture fixes that for ~0.6 s a task, so Auto sends it only on ambiguous reads. Full table: `docs/plans/2026-10-16-jev-vision.md`.
