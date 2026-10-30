# Headless Copper — a browser for a Mac nobody sits at

*`Copper --headless` (or `SEARCH_HEADLESS=1`): the same browser, run by a daemon on a headless Mac
mini — with no Dock icon, no menu bar, no window on any display, and nothing that waits for a
click. The loopback MCP server and the agent link run exactly as in the windowed app — they are
the only way in. Implementation: `Sources/Search/Fork/Headless.swift`. For the tools themselves
read [agents.md](agents.md); for the link, [agent-link.md](agent-link.md).*

## Run it

```sh
/Applications/Copper.app/Contents/MacOS/Copper --headless        # or
SEARCH_HEADLESS=1 /Applications/Copper.app/Contents/MacOS/Copper
```

It needs a logged-in GUI (Aqua) session — WebKit renders through the WindowServer — but nobody
has to look at it. Logs go to stderr, one line each, prefixed `copper[headless]:`; keys never
appear in them.

What changes when headless is on (and nothing here runs when it is off):

| | Windowed | Headless |
|---|---|---|
| Activation policy | regular (Dock icon, menu bar) | **accessory** — no Dock icon, never takes the menu bar |
| `NSApp.activate` | brings Copper forward | **ignored** (logged); if LaunchServices activates the app anyway it deactivates at once |
| Browser window | on screen | **parked outside every display** (see *The window*) |
| JS `alert` / `confirm` / `prompt`, certificate and HTTP-auth sheets, extension permission alerts | a sheet on the window | **declined on the spot** (`confirm()` → false, `prompt()` → null, bad certificate → not excused, sign-in → cancelled) and logged |
| Open/save panels (file inputs, downloads "Save as…") | a sheet | **cancelled**, logged |
| Camera / microphone asks | a bar at the bottom ([capture.md](capture.md)) | **denied**, logged — unless the site was already allowed that device |
| Keychain prompts | a dialog | none — reads that would prompt fail (`errSecInteractionNotAllowed`) |
| First-run Welcome panel | shown once | **suppressed** |
| "Reopen windows?" after a crash | AppKit may ask | off (`ApplePersistenceIgnoreState`) |
| App Nap | macOS decides | held off — the process is a server |
| SIGTERM | ends the process | a normal quit, so the session's last write is flushed |
| Session restore | silent | silent (unchanged; tabs come back) |
| `links[].announces` | `true` says each bot call in the bottom line | per-app setting; `false` is silent |

**Agent switches.** Headless has no Settings, so two switches in `agent.json` default to **on**
when the file does not mention them: `enabled` (the loopback server) and `jev` (Jev mode). An
explicit `false` is respected. An external installer may write the legacy single-app object (or the `links` array), so a fresh mini comes up serving the loopback on 4123 with Jev tools.

## The window

WebKit has to lay pages out and paint them — Jev indexes elements by geometry, agents take
screenshots, `browser_click` posts real events into the window. So the browser keeps its one
window and parks it:

- **`SEARCH_HEADLESS_WINDOW=offscreen`** (default). The window is ordered in, but placed below
  and left of every display (`Parking.origin`), with shadow, mouse events and the Windows menu
  off. AppKit keeps running layout and display for it. A window outside every display counts as
  occluded, and WebKit treats an occluded page as a background tab (no painting, no
  `requestAnimationFrame`, `document.hidden`, and in a shipped build a WebContent process that may
  be suspended), so each web view is told to ignore occlusion as it joins the window
  (`_setWindowOcclusionDetectionEnabled:`, WebKit SPI). Pages see `visibilityState == "visible"`
  and animate at display rate. `CGWindowList` shows one window, `kCGWindowIsOnscreen = true`,
  bounds outside every display.
- **`SEARCH_HEADLESS_WINDOW=hidden`**. The window is never ordered in (`CGWindowList`: zero
  on-screen windows). Snapshots, `jev_observe`, screenshots and clicks still work — the web view
  stays in its window at full size — but the page is a background tab to WebKit:
  `document.hidden`, no `requestAnimationFrame`. Fine for reading; not what the tools were tuned
  against.

`SEARCH_HEADLESS_SIZE=WxH` sets the parked window's size (default `1440x900`; the page's viewport
is that less the sidebar). The parked frame is never written to the window autosave, so the
windowed app on the same Mac comes back where it was. A screen change or anything that moves the
window back onto a display puts it back in its parking spot.

How it is wired: no upstream file is touched. The window ordering calls (`makeKeyAndOrderFront:`,
`orderFront:`, `orderFrontRegardless`, `orderWindow:relativeTo:`), `constrainFrameRect:toScreen:`,
`setFrameAutosaveName:`, `NSApp.activate…`, `NSAlert`/`NSSavePanel`/`NSOpenPanel` modal and sheet
entry points and `NSApplication.runModalForWindow:` are intercepted at the AppKit level (method
swizzling, installed only when headless is on), so every existing call site — `Links`, `Browser`,
`Extensions`, `Dialogs`, `Input` — is covered without a hook in each. `Bridge.runIfAsked` boots
headless before SwiftUI builds a window; `MCP.start(for:)` finishes it once the browser exists.

## Environment

| Variable / flag | Meaning |
|---|---|
| `--headless`, `SEARCH_HEADLESS=1` | headless mode (`1`, `true`, `yes`, `on`) |
| `SEARCH_HEADLESS_WINDOW` | `offscreen` (default) or `hidden` |
| `SEARCH_HEADLESS_SIZE` | parked window size, `WxH`, default `1440x900` |
| `SEARCH_MCP_PORT` | listen on this port instead of `agent.json`'s, without writing it back. Works in any mode; the CLI and `--mcp-stdio` honour it too (the CLI's older `COPPER_AGENT_PORT` still wins when both are set) |
| `SEARCH_HEADLESS_DEBUG` | extra parking/occlusion lines in the log |

## Intelligence: `copper intelligence`

The Jev (TypeSafe) and API-key lane settings live in `intelligence.json` beside `agent.json`
(mode 0600). The command never prints a key:

```sh
copper intelligence status
# {"jevReady":true,"routerReady":true,"routerURL":"https://llm.dev.exowatt.com","routerModel":"sonnet","jevModel":"jev-latest","lane":"key","tier":"sonnet","model":"sonnet","modelReady":true,"claudeReady":false,"claudeAccount":""}
copper intelligence set --lane key --model sonnet --jev ts-… --router-key sk-… --router-url https://llm.dev.exowatt.com --router-model sonnet --text-model haiku
echo "$ROUTER_KEY" | copper intelligence set --router-key -     # `-` reads the value from stdin (keeps it out of `ps`)
copper intelligence set --haiku-model haiku --sonnet-model sonnet --opus-model opus
copper intelligence reload                                      # re-read intelligence.json
kill -HUP <copper pid>                                          # same as reload
```

`set` accepts `--lane key|claude`, `--model haiku|sonnet|opus`, `--haiku-model NAME`,
`--sonnet-model NAME`, and `--opus-model NAME`, as well as the existing `--jev`,
`--router-key`, `--router-url`, `--router-model` and `--text-model`. A model name of `-`
is read from stdin. The result is the status plus `applied: ["lane", …]` (names, never
values). A non-http(s) `--router-url` is refused (exit 1).

`status` contains the old keys plus `lane`, `tier`, `model`, `modelReady`, `claudeReady`
and `claudeAccount`. Like `copper link`, it needs the loopback server (on by default in
headless). External writers can JSON-merge into `intelligence.json` and send **SIGHUP**;
Copper re-reads the file on the main queue and logs the reload without logging keys.

### Claude account

A headless Mac cannot click through claude.ai. Sign in once in a window, or run
`copper claude paste -` with the callback code on stdin. `copper claude signin` opens a tab
only when a running Copper window is available. `copper claude status`, `signout` and `cancel`
are also available. Alternatively keep the API-key lane with `copper intelligence set --lane key`.
The Claude account credentials live in `claude.json` (0600); status and CLI output never
contain a token.

Loopback method, for scripts that speak JSON-RPC directly (bearer from `agent.json`; loopback
only — never reachable through the agent link):

```json
{"jsonrpc":"2.0","id":1,"method":"copper/intelligence","params":{"op":"set","jevKey":"ts-…"}}
{"jsonrpc":"2.0","id":2,"method":"copper/intelligence","params":{"op":"status"}}
{"jsonrpc":"2.0","id":3,"method":"copper/intelligence","params":{"op":"reload"}}
```

## Health

`GET /health` (no auth) and `copper health --json` carry `headless: true|false`; headless adds
`headlessWindow: {window, windowsOnScreen, webViews, webViewsIgnoringOcclusion}`, and `/health`
also says the `port` actually listened on.

```sh
copper health --json
# {"headless":true,"health":{"headless":true,"headlessWindow":{"webViews":1,"webViewsIgnoringOcclusion":1,
#   "window":"offscreen","windowsOnScreen":0},"mcp":"/mcp","name":"copper","port":4123,"running":true,"version":"…"},"jev":true}
```

## launchd (an external installer's recipe)

a background installer writes `~/Library/LaunchAgents/com.example.copper.plist` (paths must
be absolute — launchd does not expand `~`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.example.copper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/USER/Applications/Copper.app/Contents/MacOS/Copper</string>
    <string>--headless</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>/Users/USER/Library/Logs/Copper/copper.log</string>
  <key>StandardErrorPath</key><string>/Users/USER/Library/Logs/Copper/copper.log</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.copper.plist
launchctl kickstart -k gui/$(id -u)/com.example.copper     # restart
launchctl bootout gui/$(id -u)/com.example.copper          # stop (SIGTERM → clean quit, exit 0, not restarted)
```

- `LimitLoadToSessionType Aqua`: the job exists only in a logged-in GUI session — WebKit needs
  the WindowServer. On a mini with no one at it, turn on automatic login.
- `KeepAlive {SuccessfulExit: false}`: a crash is restarted; a SIGTERM quit (exit 0) is not.
- Data: Copper's default folder, `~/Library/Application Support/Copper/`. The daemon JSON-merges
  `links: [{id, enabled, api, token, name: "copper", announces: false}]` into `agent.json` (0600).
- Updates (Settings › About › Updates / `updates upgrade`): Copper sees it is this job (parent launchd,
  `XPC_SERVICE_NAME` = the label), quits, gives launchd 3 s to restart it, then
  `launchctl kickstart gui/<uid>/<label>` — `SuccessfulExit: false` does not restart a clean
  quit — so the new version comes back under launchd. Every step is in
  `~/Library/Logs/Copper/update.log` (docs/updates.md).
- `ProcessType Background` puts the process under the system's background CPU/IO clamps; Copper
  is the process that drives WebKit and answers every tool call, so if Jev runs feel slow on a
  busy mini, `Standard` (or dropping the key) is the thing to try first.

## Dock clicks and ordinary `open`

LaunchServices sends a Dock click or a plain `open Copper.app` to whichever running instance it
picks — with an agent's headless probe alive, often the probe. A probe (a named test world, or a
headless run outside the main world) no longer swallows it: it never shows itself, and hands the
reopen to the main world — a reopen event and the activation LaunchServices gave the probe when
its instance lock is held, launching it (`open -n`, a clean environment) and handing the
activation over once it is up when not. LaunchServices also promotes the accessory probe to an
ordinary app as it routes the click there; the probe takes its accessory policy back at once, so
there is never a second Copper in the Dock or ⌘-Tab. A headless Copper that *is* the main world (the
launchd recipe above) handles a reopen as before. One process per world is enforced by a kernel
lock (`instance.lock`), so neither a reopen nor an update relaunch can start a second one.
Details: docs/updates.md.

Links from other apps get the same treatment. LaunchServices resolves the default browser to a
bundle id and sends the `GetURL` event to one process of that bundle — with a headless probe
alive, often the probe, which used to open the page in a world nobody could see while Copper came
forward with nothing new in it. A probe now hands the address to the main world's process by pid
(an Apple Event aimed at that one process, so LaunchServices gets no second say), launching the
main world first when nothing holds its lock and sending once it does. A headless Copper that *is*
the main world opens the link itself. `Fork/LinkRelay.swift`; every hand-off is a line in
`update.log`. The test seam (`COPPER_MAIN_WORLD=<name>`) makes a probe treat the world
`Copper (<name>)` as main — launched headless and hidden, and told it is main itself, so a chain
of test worlds never reaches the installed Copper.

All of this is about probes of a **release** build (`com.collinrijock.copper`, such as the
downloaded app `site-capture/launch.sh` runs). A probe of a development build
(`com.collinrijock.copper.dev`, below) is a different app to LaunchServices: a Dock click or a
link meant for the installed Copper never reaches it, and it hands nothing on.

## Probing it without touching a real profile

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh
open -n -g --stderr /tmp/copper-headless.log \
  --env SEARCH_PROBE=headless --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT=4193 --env SEARCH_MEASURE=1 \
  build/Copper.app            # world "Copper (headless)"; -g so it is never brought forward
export SEARCH_PROBE=headless SEARCH_MCP_PORT=4193
build/Copper.app/Contents/MacOS/Copper --cli --json health
build/Copper.app/Contents/MacOS/Copper --cli open https://example.com
build/Copper.app/Contents/MacOS/Copper --cli observe
build/Copper.app/Contents/MacOS/Copper --cli shot /tmp/headless.png
build/Copper.app/Contents/MacOS/Copper --cli intelligence set --jev ts-test
kill <that pid only>
```

`SEARCH_PROBE=<name>` keeps the data in its own world; `SEARCH_MCP_PORT` keeps it off the
windowed Copper's 4123; `SEARCH_MEASURE=1` keeps WebKit's shipped background policy, so the probe
sees what a real headless run sees.

### A development build is its own app

`./build.sh` (no `COPPER_RELEASE=1`) builds `com.collinrijock.copper.dev`, not
`com.collinrijock.copper` (docs/releasing.md). What macOS files under a bundle id is therefore
the dev app's, never the installed Copper's:

| | installed Copper | probe of a dev build |
|---|---|---|
| Privacy grants (TCC: Files & Folders, Full Disk Access, Automation…) | `com.collinrijock.copper` | `com.collinrijock.copper.dev` |
| `UserDefaults.standard` (WebKit's spelling switches, window frames) | `com.collinrijock.copper` | `com.collinrijock.copper.dev` |
| Copper's own settings (`Store.settings`) | `com.collinrijock.copper` | `com.officecommun.search.test.<world>` (unchanged) |
| Data folder | `~/Library/Application Support/Copper` | `Copper (<world>)` (unchanged) |
| WebKit container | `~/Library/WebKit/com.collinrijock.copper` | `~/Library/WebKit/com.collinrijock.copper.dev`, one store per world inside |
| Keychain | items labelled `Copper`, ACLs for the release certificate | items labelled `Copper (<world>)`, ACLs for that ad-hoc build |
| `copper://` links from other apps | yes | no (not claimed) |

Without `SEARCH_PROBE` a dev build is the world `dev` (`Copper (dev)`, suite
`com.officecommun.search.test.dev`) — it never opens the real folder. To check that a QA run left
the installed Copper alone:

```sh
defaults export com.collinrijock.copper - | shasum -a 256     # before and after: identical
log show --last 30m --style compact --predicate 'subsystem == "com.apple.TCC"' \
  | grep -o 'com\.collinrijock\.copper[.a-z]*' | sort | uniq -c   # probe events under .dev only
```

`CGWindowListCopyWindowInfo` filtered by the pid is the
reliable window count (System Events needs Accessibility, and two processes are named Copper).

### What a probe leaves alone

A test run's own seams keep it away from what belongs to the person at the Mac:

- **Their Safari.** A probe never looks at this Mac's own Safari: Move in lists Safari only
  when a script names a copy (`flow root --source Safari`), and calls it locked otherwise
  (`Fork/Flow/Flow.swift`, `FlowSafariSourceTests.aProbeNeverLooksAtThisMacsSafari`). The
  guard is `SEARCH_PROBE` itself (`Flow.probe`): a dev build opened without it (the world
  `dev`, a double-click) is not a probe, and looks at this Mac's Safari and Chrome folders like
  any Copper, as the dev app.
- **Their Chrome and Arc, if you point it elsewhere.** Chrome-family sources have no such
  guard. Before opening Move in in a probe, set `flow limit` and `flow root` to fixtures or a
  read-only copy, as every `docs/fixtures/flow-*.sh` script does; otherwise the dev app lists
  this Mac's real folders and asks macOS for Chrome's ([flow.md](flow.md#test-runs)).
- **The keychain.** A test run reads no browser's Safe Storage key: Chrome's secrets need
  `flow passphrase` (a fixture's) and land in `FlowProbeSink`, never the keychain. Copper's own
  passwords and passkeys go to a 0600 file in the world when the world asks for it
  (`defaults write com.officecommun.search.test.<world> probe.keychain -string file`, before
  launch; `ProbeKeychain`).
- **Their clipboard, editor, default browser and update log.** Settings' Copy and Open stay in
  the world, Make default is refused, and `update.log` is the world's own
  ([settings.md](settings.md#what-a-test-run-does-differently)).

## What it cannot do

- Run without a GUI login. The WindowServer is required; `LimitLoadToSessionType Aqua` says so.
- Answer anything. Every dialog is "no": a site that needs `confirm()` to proceed, a file upload,
  camera/microphone, a self-signed certificate on a public host, HTTP basic auth, or a keychain
  item that would prompt all fail closed. Passkeys that need Touch ID cannot be used. The one
  exception is Settings' own questions in a test run (Clear history, New token…, Delete space…):
  they are held for `./bench settings confirm` instead of declined
  ([settings.md](settings.md#questions-before-what-cant-be-undone)).
- Be focused. The app is never active, so `document.hasFocus()` is false — the same as a
  windowed Copper behind other apps, which the tools already handle.
- Zero windows *and* a painting page at once: `offscreen` has one ordered-in window outside every
  display; `hidden` has none but pages are background tabs.
- `./bench window` (WindowServer pictures of the window) shows the parked window's pixels only if
  the screen-recording grant allows it; use `browser_take_screenshot`.
