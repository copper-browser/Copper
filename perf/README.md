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
