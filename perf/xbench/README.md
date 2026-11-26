# xbench: Copper against other Mac browsers, measured from the outside

The numbers on [copper.exowatt.com/benchmarks/](https://copper.exowatt.com/benchmarks/) come from here. Ardia's
cross-browser bench drives its rivals over Chrome DevTools, so it only works for Chromium browsers. Copper is WebKit,
so this harness reads every browser the same way from outside the app:

| What | How |
|---|---|
| a window | `xbprobe waitwindow` polls `CGWindowListCopyWindowInfo` about every 2 ms for the first on-screen window ≥ 300×200, alpha > 0, of a process running from the browser's bundle |
| a page | the test page reports its own Navigation Timing (`load`) and paint timing (`first-contentful-paint`) to the harness's server with `sendBeacon`; times are the page's `performance.timeOrigin` + entry time, against the wall clock taken just before `open` |
| memory | `phys_footprint` summed over every process of the instance: the app, its descendants, every process macOS holds the app *responsible* for (WebKit's WebContent, Networking and GPU processes are launchd's children, not the app's) and anything running from inside its bundle (`xbprobe procs`) |
| idle CPU, wakeups, power | `proc_pid_rusage` (CPU time, idle + interrupt wakeups, `ri_energy_nj`) over the same processes at both ends of the window; processes present at both ends count, as in Ardia's harness |
| speed | Speedometer 3.1 (`WebKit/Speedometer` branch `release/3.1`) served from the same Mac; a hook in its `index.html` reports `metrics.Score.mean` when the run ends |

Tabs are opened and closed through each browser's own door, never by clicks: the DevTools HTTP endpoint for Chrome
and Ardia (`PUT /json/new`, `/json/close`), WebDriver for Safari, and the bench socket of Copper's test world
(`open`, `close`).

## Rows

| Row | How |
|---|---|
| Cold launch → window on screen | `open -n -g -a APP` with the browser closed (in the background, as a link from another app starts it), its template profile restored → first window |
| Cold launch → restored tab painted | the same launch → the restored test page's first contentful paint |
| Cold launch → page painted (link opened from another app) | `open -n -g -a APP URL` with the browser closed → that page's first contentful paint. Chrome gets `--restore-last-session` here too, as in Ardia's bench, so it restores the template's tab on the way as Copper and Ardia do by default; each sample records whether the browser did (`restoredToo`) |
| Memory, 1 / 10 / 20 tabs, back to 1 | one launch (restore): 30 s after launch; 10 s after the 10th tab loaded; 15 s after the 20th; 30 s after closing back to the first |
| Idle CPU, wakeups, power, 1 and 20 tabs | 60 s windows right after the 1-tab and 20-tab memory readings |
| Speedometer 3.1 | a fresh launch, Speedometer opened in a new tab, its score |

Each tab is the same local page (60 boxes, 120 paragraphs, a one-second timer, like Ardia's), each opened once the
one before it has loaded.

## The browsers

Every browser runs as shipped with default settings, from a copy in `~/hc/ardia-site-bench/apps-xb/` that nothing
else on the Mac runs (an instance is found by its executable's path), in a profile of its own. Each profile starts
as a copy of a template made once: one launch, the test page opened, 60 s to settle, a clean quit. So every launch
restores the same one tab.

- **Copper**: the test world `Copper (xbench)` (`SEARCH_PROBE=xbench`; `COPPER_MAIN_WORLD=xbench` so a link isn't
  relayed to the Mac's own Copper; `SEARCH_MEASURE=1`, without which a test world keeps hidden pages at full pace
  and App Nap off: in a dry run 20 hidden tabs idled at 5.3% CPU without it, 0.16% with it), its normal window at
  1280×800, for launches, memory and idle alike. Speedometer
  and the one-tab "drawing" check run headless (`SEARCH_HEADLESS=1`, 1280×800): see *The screen* below.
- **Safari**: the system's (it can't run from a copy or a profile of its own, and this Mac's Safari profile belongs
  to its owner and syncs with iCloud). Only the launch to a window is timed with `open`
  (`-ApplePersistenceIgnoreStateQuietly YES`, so it opens its Start Page and restores nothing). Memory and idle run
  in a WebDriver session (`safaridriver`), Safari's own private automation window, at 1280×800.
- **Chrome**: Google's universal download, `--user-data-dir` of its own, `--no-first-run --no-default-browser-check
  --password-store=basic --use-mock-keychain --remote-debugging-port --restore-last-session --window-size=1280,800`.
- **Ardia**: its release download, `ARDIA_DATA_DIR` and `HOME` of its own, onboarding marked done
  (`onboarding.json`, as Ardia's own harness does), `ARDIA_REMOTE_DEBUGGING_PORT`, window 1280×800 in its saved
  session. Not its background test mode (`ARDIA_BACKGROUND`), which Ardia's own bench gives Ardia.
- **Arc** is not measured: at first launch it wants an Arc account, and nobody can sign in on this Mac.

## The screen

The Mac mini's screen is locked: nobody sits at it. macOS then calls every window occluded. WebKit treats an occluded
page as hidden (no painting after the first, no `requestAnimationFrame`), while Chrome and Ardia keep drawing their
front tab (the test pages report `visible` and ~60 frames a second there). So Copper's and Safari's idle rows are
what a hidden page costs, and Chrome's and Ardia's include drawing the tab in front: a tilt toward WebKit of one
page's drawing. To size it, each round also runs Copper with one tab *drawing*: headless, whose web views ignore
occlusion (`docs/headless.md`), 30 s after launch, a 60 s idle window (rows `*-1-visible`). Headless isn't used for
the 20-tab rows because it makes every tab's page count as visible, which no windowed browser does. Speedometer needs
a page that draws, so Copper runs it headless and Safari, with no such switch, has no score. Every sample records
the visibility its pages reported.

## The runs

`xbench.py run --quiet` interleaves the browsers item by item and rotates their order each round. Each round
(about 18 minutes: every launch, session and Speedometer run of every browser) queues for `~/hc/mini.lock` like the
Mac's other jobs (builds, tests: they wait in `lockf`) and holds it for the whole round. Holding it, it asks the token
bench (`../agentbench`) to hold its next run (`~/hc/ardia-site-bench/PAUSE`) and starts once the 1-minute load
average is under 2; if the load stays up for 90 seconds, the lock goes back for 10 minutes and the round queues again, so a hold
stays under 20 minutes. Every item records the load average at its start and end.
A row's figure is the median of its runs, with min–max and n; `best` is the best
median, picked from the unrounded medians (an exact tie names no single best), not a win (compare the ranges).

An item counts only when every value its rows need came: a window and a paint for a launch, a score from a visible
page for Speedometer, every tab loaded within 15 s for a session, a drawing page for the visible check. Anything
else is recorded with its error and tried once more at the end of the run (and again by a later `run`). Each item
also records whether the display was asleep and the screen locked (`xbprobe display`), and each launch the gap
between the server's clock and the page's (`skew`).

What isn't measured: new tab, tab switch and new window (each browser needs its own driver for them, and a person's
clicks need an unlocked screen); Safari's link and restore launches (they'd write to the owner's Safari history);
power under load (scrolling, video).

## Run it

On the Mac, with the copies in place and Speedometer cloned to `~/hc/ardia-site-bench/speedometer`:

```sh
python3 perf/xbench/xbench.py check --browsers copper,safari,chrome,ardia      # one look at each, nothing kept
python3 perf/xbench/xbench.py run --out ~/hc/ardia-site-bench/out/final --quiet --rounds 3 --launches 2
python3 perf/xbench/xbench.py report --out ~/hc/ardia-site-bench/out/final --json site/assets/bench.json --md table.md
python3 perf/xbench/page.py                                                    # site/benchmarks/index.html
python3 perf/xbench/xbench.py selftest && python3 perf/xbench/page.py --check
```

`run` is resumable: finished items in `samples.jsonl` are skipped. `xbprobe.swift` is compiled on first use.

## Files

- `xbench.py`: the harness (stdlib Python); `xbprobe.swift`: the window, process and rusage probe.
- `page.py`: writes `site/benchmarks/index.html` from `site/assets/bench.json`, `site/assets/agentbench.json` and
  the Polar figures.
- `results/<date>/`: `run.json` (Mac, versions) and `samples.jsonl` (one line per item) of the published run.
- `polar-2026-11-18/`: the three Copper-vs-Polar figures the site may quote (agent speed, launch, memory) and the rows
  they come from.
