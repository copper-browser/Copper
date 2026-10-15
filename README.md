# Copper

A small, fast, quiet web browser for the Mac, by Collin and Felipe. Built on Search by Office Commun.

![Copper, with its tabs down the left and a page taking the rest of the window](.github/screenshot.png)

**[Download for macOS →](https://github.com/copper-browser/Copper/releases/latest/download/copper-macos-arm64.zip)** · `brew install --cask copper-browser/copper/copper` · macOS 14 or later · Apple Silicon · free

New to Copper? **[Getting started](docs/onboarding.md)** — install, move in from Arc, Chrome or Safari, link a Copper Cloud, use the agent.

---

## What it is

Copper is a browser with nothing in the way. A row of tabs — across the top or down the left, your choice — and the page. There is no toolbar, no start page, no sidebar of suggestions, no account to sign into, nothing that wants your attention. You type an address or a few words in one field and you are on the page.

It uses **WebKit**, the engine already inside every Mac (it is what Safari runs on). That is why the whole app is about 11 MB on disk (a 7 MB download) and opens instantly: there is no second copy of Chromium to download, update and keep in memory.

It was built by a design studio that spends its whole day in a browser and was tired of the ones that had become products. This one is a tool.

## What it does

- **One field.** Type an address and you go there; type words and you search. It finishes addresses from your own history — and from Arc's or Chrome's, whole, once you press **Bring in** under Settings › General — and from every tab you keep in any space, and never sends what you type anywhere until you press Return.
- **Tabs that stay out of the way.** Pin the pages you keep open all day and they shrink to a letter or their icon. Tabs from your last session come back instantly and cost nothing until you click them. `⌘K` lists your open tabs by name. The tab you are on is unmistakable — paper on the column, a bar in the space's colour, a heavier title — and the column scrolls to it whenever the selection moves. `⌃Tab` walks the row, or, from Settings › Tabs, flips between the tabs you used most recently ([docs/tabs.md](docs/tabs.md)).
- **Trails (preview, Settings › Labs).** Today's tabs gather into lines of intent — a search or an address you typed, and every page you opened from it, each under the page it came from. The trail you're on opens out; the rest fold to one row each, with a Glance of their pages under the pointer; trails you've left alone drift under *Earlier*. Close a whole trail with ⌘⇧W and get it back, lineage and all, with ⌘⇧T; ask the agent about it or put it on your canvas. Off until you turn it on ([docs/trails.md](docs/trails.md)).
- **Spaces.** Rows of tabs with a name, an icon, a colour the whole column wears, and optionally a profile of their own. A labelled header, icon chips at the foot, **Edit Space…** for everything, delete that offers to keep the tabs ([docs/spaces.md](docs/spaces.md)).
- **Reading mode.** `⌥⌘R` strips a page down to the article. `⇧⌘R` clears the current site's cache and reloads from origin; `⇧⌘I` opens Web Inspector's element picker.
- **Hide anything, for good.** `⇧⌘H`, then click a cookie banner, a newsletter overlay, a rail of "related" nonsense — it goes, and it is still gone on that site next time, before the page has drawn a single frame.
- **An ad blocker that runs before the page.** Third-party trackers and ad networks are stopped at the network level, so there is nothing to render and nothing to slow down. On by default, off per site if something breaks.
- **Video that follows you.** `⇧⌘P` lifts the video out of the page into a small window that stays above everything, including other apps.
- **Passwords, in your keychain.** Copper offers to save a sign-in once it has actually worked, and offers your saved accounts under the field when you click it — the way Safari does, never filling anything on its own. Everything lives in the macOS keychain, encrypted by the system, readable only by Copper. Bring yours in from Chrome, Arc, Dia, Brave or Edge in one click; nothing leaves the Mac.
- **Flow — move in from Chrome, Safari or Arc.** One button brings over open tabs, spaces, bookmarks, history, passwords, Google Password Manager passkeys, signed-in state and extensions (from Safari: open tabs and tab groups, bookmarks, the Reading List, history, and passwords from its export). Imported pages stay asleep until you visit them, and macOS asks once before handing over the other browser's key. Running it again adds only what is new, and when macOS keeps the other browser's folder private the sheet says how to let Copper in, or takes the browser's export instead ([docs/flow.md](docs/flow.md)).
- **Light, dark, or the Mac's own.** The frame and the pages follow.
- **Bookmarks, history, downloads** — each a panel, each searchable, each one keystroke away. A download shows a small door with a progress ring while it arrives and a popover with speed, time left, cancel, retry and Show in Finder — and nothing at all when there is nothing to show ([docs/downloads.md](docs/downloads.md)).
- **Chrome extensions, without Chrome.** Paste a Chrome Web Store link in Settings › Extensions, or open the extension's page in Copper and press Add. It runs on WebKit's own extension engine — the one Safari uses — and where Chrome has APIs WebKit doesn't (bookmarks, history, downloads, side panel, offscreen documents, fonts, notifications, speech, OAuth sign-in), Copper fills them in itself. They live behind the puzzle button; pin the ones you use often. Building your own? Load its folder as an unpacked extension and press Reload after each change, as in Chrome's developer mode. macOS 15.4 or later. The iCloud Passwords Chrome extension is incompatible with Copper and stays off because it can crash sign-in pages; its data is kept. Use Settings › Passwords to import a passwords CSV, or a supported password manager instead. ([Why and recovery checks](docs/crashes.md#sign-in-pages-that-keep-refreshing).)
- **Copper Cloud, if you want it.** Link Copper to a copper-cloud instance you (or your team) run, sign in, and choose what follows you between Macs: spaces and their kept tabs, the look-and-behaviour settings, bookmarks, history, and a view of the tabs open on your other Macs. Off until you turn it on; the instance is pinned by its certificate; your token stays in a file only you can read ([docs/cloud.md](docs/cloud.md)).
- **Updates itself, quietly.** Once every six hours it checks Copper's GitHub releases. A newer build is downloaded and verified in the background first; only then do Settings › Updates and ⌘K offer **Update**, which backs up your tabs, swaps the new Copper in and relaunches — a few seconds. Anything that fails on the way says so, in a sentence, in Settings › Updates.

## What it doesn't do

On purpose:

- No extension you have to install to feel at home. Blocking ads, hiding clutter, reading mode, picture-in-picture and passwords are built in; extensions are there for everything else.
- No sync, no account, no cloud — unless you link it to a Copper Cloud instance you run yourself, which is off until you turn it on and never carries passwords. Otherwise your tabs, history and passwords are on your Mac and nowhere else.
- No telemetry, no analytics, no crash reports sent anywhere. The only things that leave your Mac are the pages you ask for, their icons, and one small request a day to see whether there is a newer version.
- One window. Tabs are the only kind of "new" there is.

## Privacy, concretely

| What | Where it is | Who can read it |
|---|---|---|
| Passwords | The macOS login keychain, as ordinary keychain items tagged `Copper` | Copper, signed with Copper's release certificate. Any other app triggers the system's permission dialog. |
| History, bookmarks, open tabs, hidden elements | Small JSON files in `~/Library/Application Support/Copper/` | You. |
| Cookies and site data | WebKit's own store for the app | The sites that set them, as in any browser. |
| Extensions | Unpacked in `~/Library/Application Support/Copper/Extensions/`, their data in WebKit's extension store | Each extension, within the permissions you accepted when adding it. |
| Copper Cloud (only if you link it) | The domains you switched on, on the instance you linked — encrypted at rest with your account's key; the link and session token in `cloud.json` (0600) | You, and that instance's operator. |
| Anything else | Nowhere. There is no server. | — |

A **private tab** (`⇧⌘N`) has its own cookie jar and leaves nothing behind when it closes.

## Updating

Copper checks `https://github.com/copper-browser/Copper/releases/latest/download/copper-version.json` (the manifest attached to the newest release) after launch and then every six hours. It never restarts without your say-so.

Everything that can fail happens before you are asked. When the manifest names a newer release, Copper downloads the archive from the feed, checks it against the manifest's SHA-256, unpacks it under `~/Library/Application Support/Copper/updates/<version>/`, and checks that the bundle is Copper, is that version, and that its code signature verifies and is Copper's own (the release certificate and requirement in `release/`, docs/releasing.md). Only then does **Settings › Updates** say *Copper X is ready* and offer **Update** (also ⌘K › **Update Copper**). Update backs up `session.json` (ten copies are kept), moves the running bundle to `updates/previous/`, moves the verified one into its place, and relaunches; the tab session comes back as it was. A refused swap puts the old bundle back and says why.

Whatever goes wrong is shown where it happened: a download or verification failure sits under the release with a **Retry** button and the reason (`did not match the feed's checksum`, `answered 404`, `the signature did not verify`, …); a refused update stays as *The last update didn't finish* with the reason and an **Open log** button (`~/Library/Logs/Copper/update.log`, one dated line per step). Offline checks stay quiet; a failed download after a successful check is announced once per release.

### Installing

```sh
brew install --cask copper-browser/copper/copper      # Homebrew (tap: copper-browser/homebrew-copper)
curl -fsSL https://github.com/copper-browser/Copper/releases/latest/download/copper-install.sh | sh
```

Or download [`copper-macos-arm64.zip`](https://github.com/copper-browser/Copper/releases/latest/download/copper-macos-arm64.zip) from the [latest release](https://github.com/copper-browser/Copper/releases/latest), move `Copper.app` to `/Applications` and run `xattr -cr /Applications/Copper.app` once — builds are signed with Copper's own certificate, not notarized, and Homebrew and the installer clear the quarantine flag for you. Because every release carries the same signature, the permissions you give Copper (Full Disk Access, Files & Folders, the keychain's Always Allow) survive updates. Apple Silicon, macOS 14 or later.

`brew upgrade --cask copper` (by name) still works as a manual path; the cask declares `auto_updates` so a plain `brew upgrade` leaves the app to update itself. Re-running the curl installer is the other manual path.

Releases are cut by `.github/workflows/release.yml` (`gh workflow run release.yml -R copper-browser/Copper -f ref=fork`): it builds on a GitHub-hosted Mac, stamps `<VERSION>.<YYYYMMDD>.<run>` into the bundle, signs it with Copper's release certificate (docs/releasing.md; `-f publish=false` is a dry run that keeps the signed zip as the run's artifact), and attaches the zip, its `.sha256`, `copper-version.json` and `copper-install.sh` to a `v<version>` release. The tap bumps its cask from that manifest.

The installer accepts `COPPER_NO_LAUNCH=1` / `--no-launch` for scripts that want to relaunch separately. For the bench: `./bench updates status|check|stub URL|stage|dry-run on|off|upgrade` — `stub` points a test world at a local manifest, `stage` downloads and verifies now, `dry-run on` makes `upgrade` stop after the checks and the session backup and log what it would have swapped.

## Keyboard

| | |
|---|---|
| `⌘L` address · `⌘K` switch tab · `⌘T` new tab · `⌘W` close · `⇧⌘T` reopen | `⌘[` `⌘]` back, forward · `⇧⌘[` `⇧⌘]` previous, next tab · `⌘1`–`⌘9` jump |
| `⇧⌘S` tabs across the top or down the left · `⌘S` fold the sidebar away · `⇧⌘B` bookmark this page | `⌥⌘R` reading mode · `⇧⌘R` hard reload · `⇧⌘I` inspect element · `⇧⌘P` float the video · `⇧⌘H` hide something · `⇧⌘U` what is hidden here |
| `⌘F` find · `⌘D` duplicate tab · `⇧⌘C` copy address · `⇧⌘V` paste and go | `⌘Y` history · `⇧⌘J` downloads · `⌘,` settings · `⌥⌘L` passwords |
| `⌘E` agent pane · `⌥⌘J` driver timeline (who is driving the page, and what they are doing) · `⌥⌘E` close every pane · `⇧⌘D` split | `⌃N` new space · `⌃⌥←` `⌃⌥→` previous, next space · `⌃1`–`⌃9` jump to a space · `⌃⇧E` new canvas · `⇧⌘O` the Personal canvas |

`⌃Tab` walks along the row of tabs, or flips between your most recent tabs (Settings › Tabs); plain `Tab` is the page's, and in the address field, `⌘T` and `⌘K` it takes the completion on offer; `esc` puts away whatever is open. `⌘←` and `⌘→` move the caret when you are typing and go back and forward otherwise; a middle click opens a link behind the current tab; the thumb buttons on a mouse go back and forward over a page, or switch to the previous/next space over the sidebar.

---

## For developers

### Why the source is here

So anyone can read exactly what a browser handling their passwords and history is doing, build it themselves, or fix something that bothers them. The code is small enough to actually read — about 12,700 lines of Swift, no dependencies beyond what Apple ships with macOS, one file per concern.

### Building it

- macOS 14 or later, Xcode 16 / Swift 6 toolchain
- `swift build` — runs the app straight from the SwiftPM binary
- `./build.sh` — assembles a real, double-clickable `Copper.app` in `build/`, ad-hoc signed so it runs on your own Mac. It is the development app, `com.collinrijock.copper.dev`: its own permissions, settings, cookies and keychain identity, always a test world (`Copper (dev)` unless `SEARCH_PROBE` names one), so it never touches an installed Copper. `COPPER_RELEASE=1` builds Copper itself (docs/releasing.md)

A build you make yourself won't be notarized or carry Copper's release certificate, so the first launch may need a right-click → Open (or an allow in System Settings → Privacy & Security). That's expected — it's the same thing that happens with any app that isn't from the App Store or a notarized DMG. Your own build also keeps its passwords apart from a released Copper's: it is a different app to macOS (`com.collinrijock.copper.dev`), and the keychain tells the two apart by their signatures.

`./build.sh release dmg` also makes `Copper.dmg` / `Copper.zip`. `./build.sh release ship` additionally notarizes and staples — that step needs a Developer ID certificate and Apple credentials, so it only really does anything for our releases.

### How it's put together

- **SwiftUI** for everything drawn, **AppKit** for the handful of things SwiftUI doesn't reach on macOS (the window's title bar, dragging the window by an empty part of the tab row), **WKWebView** for pages.
- One `Tab` per page. Its web view is built lazily — a tab restored from last session doesn't cost a process until you switch to it. That's most of why launching with twenty tabs is still instant. Each page runs in WebKit's own content process, as in Safari; a tab you close is really gone.
- The ad blocker is a `WKContentRuleList` compiled once at launch and enforced inside WebKit's networking, before a request is made — zero cost at run time, unlike a JavaScript blocker.
- Hidden elements are a per-site list of selectors injected as a stylesheet at document start, so nothing is ever seen appearing and vanishing.
- Every colour is a light/dark pair in `Design.swift`, resolved by the window's appearance; nothing else in the code knows which mode it is in.
- Extensions run on `WKWebExtension` (macOS 15.4+). `Crx.swift` fetches an extension from the Chrome Web Store's public update address and checks the CRX3 signature against the extension's id before anything is unpacked. `Extensions.swift` is the browser's side of WebKit's contract — tabs, the window, permissions, popups. `ExtensionShims.swift` adds, at install, a small script to the extension's worker, pages and content scripts: it defines the Chrome APIs WebKit lacks — `userScripts`, `privacy`, `browsingData`, `sessions`, the old FileSystem API and more — as calls answered natively by Copper, and mends the places where WebKit behaves differently from Chrome: replies from pages that don't answer, listeners added after a worker starts, workers WebKit loses track of, members and constants it leaves out. Extension pages are served from `chrome-extension://<id>/`, the address they have in Chrome, so servers and sites recognise them. `./bench ext-*` drives all of it from the shell against a test run. `ExtensionNative.swift` speaks Chrome's native messaging to hosts registered in Chrome's `NativeMessagingHosts` folders.
- `Sources/Search/` is one file per concern: `Vault.swift` is the keychain, `Shield.swift` the ad blocker, `Curtain.swift` the hidden elements, `Session.swift` what comes back at launch, `Updater.swift` the update, `Bench.swift` the test socket, and so on. There's no framework of its own to learn first.

### Testing it without closing it

Turn on **Settings › General › Let a script drive Copper** and the running app listens on a Unix socket in its own folder (readable by your user only). `./bench` at the root of the repository speaks it:

```
./bench open https://example.com     # a tab of its own, at the end of your row, marked with a flask
./bench wait 2e7e7e89                 # until it has loaded
./bench text 2e7e7e89                 # the page's text
./bench shot 2e7e7e89 out.png         # a picture of it
./bench click 2e7e7e89 "button.go"    # click, type, submit — through the page's own events
./bench probe                         # the window's state: open panels, a modal, every window
./bench close all
```

Bench tabs are never selected for you, never enter the session or the history, and go when the script says so. It is how this browser is tested while somebody is using it.

Settings has checks of its own — every control named and reachable from the keyboard, every search entry landing on its row, every destructive question answerable by a script — in [docs/settings.md](docs/settings.md).

### Command line

Copper ships a `copper` command and a Jev-first `/jev <goal>` command for driving the signed-in browser already open on your Mac. In **Settings › Agents › Terminal agents**, press **Set up** for phi, **Set up** for Claude Code, or **Install** for the CLI; Copper merges its current token into the user-scoped config and writes the command file, so no bearer token needs to ride in a pasted prompt. First enable **Settings › Agents › Let agents drive this window**. For Claude Code, start a new session after setup.

The CLI shim lives at `Copper.app/Contents/Resources/bin/copper` (Homebrew links it into your `PATH`) and never starts Copper implicitly. If the browser is down it prints one safe error and exits 2; add `--launch` (or set `COPPER_LAUNCH=1`) when you explicitly want the current launch-and-wait behaviour. `/jev` and `copper run` hand Jev the whole goal as the first call; there is no tab-list or snapshot reconnaissance first.

```sh
copper tabs
copper health
copper run "find the Acme invoice for March 2026 and stop when it is visible"
copper observe --no-text -n 20
copper session list
copper session restore                 # previous backup; add --quit if Copper is running
```

Use `copper extract "…"` for structured reads, `copper shot` for a screenshot, and `copper --json …` when a script needs the result object. Jev actions return a claim of DONE; verify the page yourself. `copper session list` reports both `session.json` and the one retained `session.previous.json` backup with tab/space counts and mtimes. `copper session restore [PATH]` saves the current file as `session.replaced-<timestamp>.json`, then restores a chosen file and relaunches Copper; it refuses to touch a running browser unless `--quit` is explicit.

Model access lives in Settings › Intelligence: choose an API-key gateway or a Claude account, then pick Haiku, Sonnet or Opus. The same model choice serves the agent pane and Jev helpers; see [docs/intelligence.md](docs/intelligence.md).

### Agent links

**Settings › Agents › Your agents — let them use this browser** lets bots in one or more agents apps use the same tools as local agents. Copper dials out (nothing new listens on your Mac), each bot gets access only after you grant it, every call shows as `@bot · app · tool` and under *Recent calls*, and *Revoke link* takes the tools away from that app's bots. Paste a personal token (`fxb_…`) minted at Agents › Connect in your agents app; it stays in `agent.json`, readable by you alone. From the shell: `copper link status|add|remove|--app SELECTOR …`. Details in [docs/agents.md](docs/agents.md#your-agents--let-them-use-this-browser); how it is built in [docs/agent-link.md](docs/agent-link.md).

### Sessions

Copper refuses to replace a non-empty session with an empty shape while launch-time restoration is still in progress. Writes remain atomic, and a single `session.previous.json` is rotated before a write drops the tab count below half (or to zero). If a quit or upgrade goes wrong, use the CLI recovery command above or press **⌘K → Restore previous session**; the command appears only when the backup exists.

### Website

The landing page at <https://copper-browser.github.io/Copper/> is `site/` (static, no build step). Any push to `fork` that touches `site/` republishes it through `.github/workflows/site.yml` (GitHub Pages via Actions). The screenshots and loops are real captures made with `site-capture/`. Hosting, CI/CD, editing rules and the capture recipe: [docs/website.md](docs/website.md).

### Contributing

Issues and pull requests are genuinely welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how this is reviewed and what tends to get merged. The short version: small changes, no new dependencies, nothing that phones home.

### License

MIT — see [LICENSE](LICENSE). Do what you want with the code. Copper and the app icon are Collin and Felipe's; it is built on Search by Office Commun.
