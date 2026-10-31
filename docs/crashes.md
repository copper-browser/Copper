# Crashes — every one kept, on this Mac, readable

*When Copper crashes, macOS writes a report to `~/Library/Logs/DiagnosticReports` that nothing
used to read. Copper now takes its own reports in at the next launch, keeps them with a summary
and what it was doing just before, and shows them in a terminal, to an agent, and in Settings.
Nothing is sent anywhere. Implementation: `Sources/Search/Fork/Crashes.swift` (ingest),
`CrashesRead.swift` (CLI, tool, symbols), `CrashesUI.swift` (Settings), `Breadcrumbs.swift`
(the trail).*

## Where it lives

Everything is in the world's data folder (`Store.folder` — so a test world keeps its own):

| | |
|---|---|
| `crashes/` | a copy of each `Copper-*.ips` / `ExcUserFault_Copper-*.ips`, and `crashes.json`, the index |
| `logs/trail.log` | the breadcrumbs; `trail.previous.log` is the one before (rotated at ~1.5 MB) |
| `dsyms/<version>/` | where a release's dSYM goes for `--symbolicate` (nothing puts one there for you) |

The index keeps the newest 50: when, version and build, macOS, exception / signal / codes, how
it ended, the crashed thread's top 20 frames as the report has them, the app binary's UUID and
load address, and that run's breadcrumbs up to the crash. A report it can't parse is still
copied and gets a minimal entry. Upstream's `crash.log` (uncaught Objective-C exceptions,
`Links.watchForTrouble`) is folded in at the same time and removed — an exception whose abort
also has a report becomes that report's reason.

Ingest runs once per launch, on a utility queue three seconds after the window — never on the
main thread, never a dialog.

## The trail

One line per event, written straight through (`O_APPEND`, no buffer), from any thread:

```
2026-10-07T04:13:40.123Z 5511 launch version=1.0.20261007.31 build=202610070207 macos=27.0.0 headless=no world=main
2026-10-07T04:13:41.002Z 5511 tool name=browser_click tab=1a2b3c4d ms=212 result=ok
2026-10-07T04:13:44.870Z 5511 tool name=browser_evaluate tab=1a2b3c4d ms=31 result=error class=Failure
2026-10-07T04:14:40.000Z 5511 pulse mem=812MB tabs=14 views=6
2026-10-07T04:15:02.311Z 5511 webcontent-gone host=example.com front=no
2026-10-07T04:15:09.874Z 5511 webcontent-loop host=example.com
2026-10-07T05:01:10.004Z 5511 quit
```

Metadata only: tool names, a tab's short id, durations, ok or the error's type (never its
message), a host (never a path or query), the memory footprint and tab / web-view counts once a
minute. Never page content, form values, typed text, cookies or a tool's arguments.

`webcontent-loop` is a tab on screen whose page took its process down three times in half a
minute: Copper stopped loading it again and shows *This page keeps closing as it loads.* with
Try again. macOS's own log says why the process went (`log show --predicate 'process ==
"Copper" AND eventMessage CONTAINS "invalid message"'` for one WebKit refused).

A launch line with no `quit` after it is a run that died. If macOS left no report for it —
jetsam, `kill -9`, a force quit, power loss — it gets an entry of its own ("quit unexpectedly,
no report"), which its report replaces if one turns up later.

## Reading it

```sh
copper crashes                       # newest first: time, version, what, first frame in Copper
copper crashes show 1                # one in full: ending, frames, breadcrumbs
copper crashes show 1 --symbolicate  # Copper's frames by name, from a matching dSYM
copper crashes path                  # the folder
copper --json crashes [show N]       # the same as JSON
```

It reads the data folder itself, so it works with Copper down. Agents get the same from the
`browser_crashes` tool (`index: N` for one in full). Settings › Copper › About shows *Last
crash: <when>, <what>* with Reveal in Finder and Copy Report — only when there has been one.

## Symbols

Release builds ship stripped, so Copper's own frames are bare offsets. The release workflow
attaches `copper-<version>-macos-arm64.dSYM.zip` to each release (from the first release made
with this change on — earlier ones kept none), and `copper-<version>-macos-x86_64.dSYM.zip` for the
Intel build from the first release that had one; `--symbolicate` names the one for the crashed
binary's CPU. `--symbolicate` looks for a dSYM whose UUID is
the crashed binary's in `dsyms/<version>/`, beside the app (`build/Copper.app.dSYM` for a
worktree build) and in `./build/`, and runs `atos` with the load address from the report.
Without one it prints the asset's URL and the `ditto` line that puts it in place; it never
downloads anything.
