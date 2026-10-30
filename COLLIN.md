# What Collin is working on — Copper

Copper is Collin's fork of [Search](https://github.com/driceroland/Search), the 3 MB WebKit browser for macOS by Office Commun. The goal is an Arc-class replacement built on WebKit: spaces, profiles, split view, a command bar, and the rest of the daily Arc features, without a Chromium engine. On top of that, Copper adds a Liquid Glass aesthetic for macOS 26, deep customizability through one theme file and one settings pane, and a sidebar widget board. Scope: Part 1, Part 1b A/B/D and Part 2 of FORK-PLAN.md, in the order listed there.

**Not Collin's — Felipe owns the agent side:** MCP integration (Copper as an MCP server / client) and any Jev integration. Those sections stay in the plan below for context only; do not start them from this document. Stagehand-style automation is **dropped**: Jev mode (`jev_run` act, `jev_extract` extract, `jev_observe` observe) covers it natively, no second automation layer needed.

## Where things live

- `main`: pristine mirror of `upstream/main`. Fast-forward only, never committed to directly.
- `fork`: the release branch. `main` plus the patch stack. Build and ship from here.
- `feat/*`: one branch per plan item while it is in progress.
- `Sources/Search/Fork/`: all new code. Upstream files are touched as little as possible, with one-line hooks into this folder.
- `PATCHES.md`: manifest of every patch that touches an upstream file (what, why, upstream status, when to drop).
- `FORK-PLAN.md`: the plan. Copied verbatim at the bottom of this file.

## Releases, signing and the dev app

Full story: `docs/releasing.md`.

- **Releases are signed with Copper's own certificate** (self-signed, `CN=Copper Release Signing`, public half and SHA-1 in `release/`; the `.p12` is the repo secrets `COPPER_SIGNING_P12_BASE64` + `COPPER_SIGNING_P12_PASSWORD`) and the explicit designated requirement in `release/designated-requirement.txt`. Not a Developer ID, not notarized.
- **Why it matters:** macOS files Full Disk Access, Files & Folders, Automation and keychain "Always Allow" under the app's designated requirement. Ad-hoc releases had a different one every build, so every update silently dropped them (Move in couldn't read Chrome after an update). Now every release has the same one, and the updater refuses any download that doesn't satisfy it.
- **Cut a release:** `gh workflow run release.yml -R copper-browser/Copper -f ref=fork`. **Dry run:** `--ref <branch> -f publish=false` builds, signs, checks and launches it, and keeps the zip as the run's artifact; nothing is published.
- **Rotate the certificate** (expires 2036-10-04, or if the key leaks): `docs/releasing.md` › Rotating. It needs a bridge release that accepts both certificates, and costs one re-grant.
- **`./build.sh` builds the dev app, `com.collinrijock.copper.dev`**: own permissions, settings, cookies and keychain identity, always a test world (`Copper (dev)` when no `SEARCH_PROBE`), no `copper://` scheme. It can't touch the Copper you use. `COPPER_RELEASE=1 ./build.sh release app` builds Copper itself, which only the release workflow needs.
- **Move in and Settings after a live demo (October 2026):** what broke, what changed (#46, #48, #49) and which tests catch each failure if it comes back: `docs/plans/2026-10-07-move-in-and-settings.md`. How Settings is built and checked: `docs/settings.md`; Move in: `docs/flow.md`.

## Status

| Item | Tier | Status |
|---|---|---|
| Fork + plan | Setup | done |
| 1. Spaces (workspaces) | Tier 1 | **shipped** (`Fork/Spaces.swift`) |
| 2. Profiles per space | Tier 1 | **shipped** (space context menu › Profile) |
| 3. Split view (2–4 panes) | Tier 1 | **shipped**, 2 panes (`Fork/Split.swift`, ⌘⇧D) |
| 4. Command bar | Tier 1 | **shipped** (`Fork/CommandBar.swift`, ⌘K) |
| 5. Folders in the sidebar | Tier 2 | **shipped** as manual tab groups (`Fork/Groups.swift`, `GroupsUI.swift`); automatic grouping was removed |
| Flow (move in from Chrome/Arc) | Copper | **shipped** (Felipe): one-button import sheet, spaces/tabs/bookmarks/history/passwords/cookies/extensions core, command bar, Settings, menu and `bench flow` |
| Copper passkeys (agent/auth lane) | Copper | **in progress**: unentitled WebAuthn polyfill, keychain P-256 credentials, Touch ID bridge, Settings list, and `bench passkeys`; Chrome import uses the same store |
| 6. Auto-archive | Tier 2 | **shipped** as part of the Sections piece: Today rows close through the normal path after 12h/24h/48h/never (`Fork/Sections.swift`, Settings, `bench sections archive`) |
| Gauntlet · sidebar | Arc-grade | **shipped** (`Side.swift` reshaped, `Fork/SpaceTint.swift`, `Fork/Marks.swift`): space-tinted column, 3-wide favourites grid, 13px rows with real favicons, paper-white live pill, filled New Tab seam row |
| Gauntlet · sections | Arc-grade | **shipped** (`Fork/Sections.swift`, `Session.Entry.saved`/`.seen`): Favourites / Saved / Today for real; arc-import marks Arc pinned as saved; drag or context menu across the seam |
| Gauntlet · folders | Arc-grade | **shipped** (`Fork/Folders.swift`, `GroupsUI.swift`): groups drawn as Arc's nested folders from ` › ` names, chevron + tinted folder glyph, 16pt indent per level, New Folder Inside, `bench groups toggle` |
| Gauntlet · command bar | Arc-grade | **shipped** (`Fork/CommandPalette.swift`): floating 640pt card, 40pt rows with site marks and a right-side hint, Switch to <space>; **partly**: input is 17.5pt not Arc's ~18, no extension-action rows |
| Gauntlet · split | Arc-grade | **shipped** (`Fork/SplitPane.swift`, `SplitSpill.swift`): panes as rounded cards in an 8pt gutter, per-pane toolbar (← → · title · ✕), live pane outlined in the space hue, hover divider; **partly**: still 2 panes |
| 7. Little Arc | Tier 2 | not started |
| 8. Peek | Tier 2 | not started |
| 9. Site Search / search engine choice | Tier 2 | not started |
| 10. Boosts (per-site CSS/JS) | Tier 2 | not started |
| 11. Space colour theming | Tier 3 | not started |
| 12. Pinned tab favicons + reset to pinned URL | Tier 3 | not started |
| 13. Tab search across spaces | Tier 3 | **shipped** with the command bar (⌘K lists other spaces’ pages) |
| 14. Media controls / now-playing in sidebar | Tier 3 | not started |
| 15. Downloads tray in sidebar | Tier 3 | not started |
| 16. Reader mode auto-detect + Ask on page | Tier 3 | reader auto-detect only; Ask on page **shipped** on the agent side (⌘⇧E opens the agent pane with the page in front) |
| A. Apple aesthetic (Liquid Glass) | Part 1b | not started |
| B. Customizability | Part 1b | not started |
| C. MCP integration (server, then client) | Part 1b | **Felipe's**, not Collin's — see note at top. Server **shipped** (`Fork/MCP/`, Settings › Agents, Playwright-MCP tool names, `--mcp-stdio` bridge, `docs/agents.md`). **Jev mode shipped** (`Fork/MCP/Ultrafast.swift`: jev-ultrafast in the open tab — `jev_run` / `jev_step` / `jev_observe` / `jev_extract`, Copy-prompt pills; 10-game Wikipedia bench 5.3× median vs Sonnet on the Playwright tools). **CLI shipped** (`copper` shim + `Copper --cli`, with `copper run` / observe / extract / screenshot commands; `copper setup phi|claude|cli|status`). CLI launch is now opt-in (`--launch` / `COPPER_LAUNCH=1`) with session list/restore and guarded backups. **Terminal setup shipped** (`Fork/MCP/Setup.swift`: token-free phi/Claude/CLI setup and status). **Client (C2) shipped** as a pane beside the page (⌘E, `Fork/Agent/`): chat with Copper's tools bound locally + mcp.json servers (HTTP + stdio). Ask on page (#16) = ⌘⇧E. **agent links shipped** (`Fork/MCP/Link.swift` + `LinkWire.swift`: Copper dials out to agents apps and serves its MCP tools to granted bots; Settings › Agents › one card per app, `copper link …`). **Driver timeline** (`Fork/MCP/Drive.swift` + `DriveCard.swift`: the pill / ring / trail, and a live card in the agent pane's conversation for every outside driver — Jev, loopback agents, linked bots; the pane agent's own Jev runs nest in its steps — with Stop refusing an agent's next calls). **Headless mode** (`Fork/Headless.swift`, `docs/headless.md`: `Copper --headless` / `SEARCH_HEADLESS=1` — accessory app, window parked off every display so WebKit still paints, dialogs auto-declined, no activation; `copper intelligence status\|set\|reload` + SIGHUP reload of `intelligence.json`; `SEARCH_MCP_PORT` override; `headless` in `copper health --json`) for a headless Mac mini's LaunchAgent. Moves into the widget board (D7) when D exists |
| D. Sidebar widgets | Part 1b | not started |
| Maintenance automation (sync workflows, PATCHES.md, release) | Part 2 | **partly shipped**: `PATCHES.md`, updater off, Copper bundle id, fork-owned feed updater (`Fork/Updates.swift`), `sync-main.yml` + `sync-fork.yml` (Layers 1–2). Left: agent conflict step (Layer 3, wait for the first conflict), release-on-tag |

## How to help / coordinate

- Open an issue before a big change, same as upstream's CONTRIBUTING asks. Small fixes can go straight to a branch.
- Prefer new files under `Sources/Search/Fork/` over edits to upstream files. Anything upstream does not have cannot conflict on the next rebase.
- If you must touch an upstream file, add or update the row in `PATCHES.md` in the same commit.
- Ping Collin on Slack before starting on a plan item so we do not both pick up the same one.
- **Windows and Linux follow the Mac.** A PR that changes something a user sees gets a row (or an updated row) in [copper-windows/docs/parity.md](https://github.com/copper-browser/copper-windows/blob/main/docs/parity.md), the checklist both ports work from, in the same week. Toolkit-free logic belongs in copper-linux's shared crates (`copper-shell-core`, `copper-core`, …) so both get it once.

---

## The plan (verbatim copy of FORK-PLAN.md)

# Fork plan: Search → Arc-class features

Fork: `copper-browser/Copper` · upstream: `driceroland/Search` (single-author, one squashed commit, v1.0).

Ground truth from the code (as of fork):

- `Browser.swift` (1.9k lines) is the model: `@Published tabs: [Tab]`, `activeID`, pins, ghosts, find, omnibox, passwords — everything.
- `Tab.swift` owns one lazy `WKWebView`; sleeps after 30 min; restores from `Session.swift` (`session.json`: flat `[Entry{url,title,pin}]` + `active`).
- `App.swift` → single SwiftUI `Window("browser")`, "one window, on purpose". `Extensions.swift:801` also folds new windows into tabs.
- `Side.swift` / `TabBar.swift` = vertical / horizontal tab UIs. `Stage.swift` = the page area (single `WebStage`).
- `Store.swift` = files under `~/Library/Application Support/Search/`, `UserDefaults` at `Store.settings`.
- Web Inspector is already on (`Tab.swift:280 isInspectable = true`).
- Chrome extensions via `WKWebExtension` + `ExtensionShims.swift` (macOS 15.4+).

"Low code" here means: reuse `Browser`/`Tab`/`Session`, add a field or a file, never a framework. Every item below says what to add and where.

---

## Part 1 — Arc features, ordered by importance

Ordering = (how much of daily Arc use it covers) × (how cheap it is here). Do them in order; each one is shippable alone.

### Tier 1 — the reasons people stay on Arc

#### 1. Spaces (workspaces) — **the** missing feature
- **Arc:** named spaces, each with its own tabs/pins, colour, swipe to switch, ⌃1–9.
- **Low-code design:** don't touch `Tab`. Add `var space: UUID` to `Tab` and `Session.Entry`. Add `Space { id, name, tint, order }` list persisted in `Store.file("spaces.json")`. `Browser.activeSpace: UUID`. Every place that reads `tabs` for display (`Side.swift`, `TabBar.swift`, `⌘K` list, `⌘1–9`) filters by `activeSpace`. Everything else (`close`, `select`, `ghosts`, session write) stays untouched because the array is still flat.
- **UI:** space switcher at the bottom of `Side.swift` (dots/names, like Arc), swipe-with-two-fingers via existing `Swipe.swift` hook, `⌃⌥←/→` and `⌃1–9`.
- **Pins per space:** already free — pins are per-`Tab`, tabs are per-space.
- **Migration:** on first read, `Entry.space == nil` → default space.
- **Effort:** ~300 lines. Files: `Tab.swift`, `Session.swift`, `Browser.swift`, `Side.swift`, `TabBar.swift`, new `Spaces.swift`.

#### 2. Profiles per space (separate cookies/logins)
- **Arc:** a space can bind to a profile → separate `WKWebsiteDataStore`.
- **Low-code:** `Space.profile: String?`. In `Web.configuration(shy:)` → `Web.configuration(store:)`; `Store.websites` becomes `Store.websites(for: profile)` returning `WKWebsiteDataStore(forIdentifier: UUID)` (macOS 14 API — persistent, per-id). `Tab.build()` picks the store from its space. Passwords: `Vault` already keys by host; add profile to the key or accept shared keychain (Arc shares too — accept).
- **Gotcha:** extensions attach per configuration; already handled per view in `Extensions.attach(config)`.
- **Effort:** ~80 lines. Files: `Tab.swift`, `Store.swift`, `Spaces.swift`.

#### 3. Split view (2–4 panes)
- **Arc:** drag a tab beside another; panes share the sidebar entry.
- **Low-code:** `Browser.split: [Tab.ID]` (ordered, active-pane index). `Stage.swift`: replace single `WebStage(page:)` with `HSplitView { ForEach(split) { Page(tab:) } }` — SwiftUI's `HSplitView` gives resizable dividers for free. Selecting a tab while holding ⌥ (or "Open in split" from tab context menu, `⌃⌥=`) appends; `⌘W` on a pane removes from `split`, not from `tabs`. Session: persist `split` ids in `Shape`.
- **Effort:** ~120 lines. Files: `Stage.swift`, `Browser.swift`, `Session.swift`, `TabBar.swift` (context menu).

#### 4. Command bar (Arc's ⌘T "do anything")
- **Arc:** one palette for URL / search / open tabs / bookmarks / history / commands.
- **Low-code:** `Omnibox.swift` already suggests from history; `⌘K` already lists open tabs. Merge: `Browser.guess()` appends sections for open tabs (`tabs.filter title/url contains`), bookmarks (`Bookmarks.all()`), and a static command list (`[("New Space", newSpace), ("Toggle Sidebar", toggleSidebar), …]`). Render sections in the existing suggestion dropdown. Bind `⌘T` to open it with an empty new tab behind it (it already does).
- **Effort:** ~150 lines. Files: `Omnibox.swift`, `Browser.swift`.

### Tier 2 — the things you'd miss in the first week

#### 5. Folders in the sidebar
- `Tab.folder: String?` + collapsible `DisclosureGroup` grouping in `Side.swift`. Persist via `Session.Entry`. Drag-to-folder reuses the existing `take(_ providers:)` drop code.
- ~100 lines.

#### 6. Auto-archive ("Today" tabs clear after N hours)
- Arc moves unpinned, untouched tabs to Archive after 12h/24h/7d/30d.
- `Tab.lastSeen: Date` (already have sleep timer logic — reuse its timestamp). On launch and hourly: unpinned tabs with `lastSeen < now - setting` → append to `ghosts` (the existing reopen-closed list, make it persistent in `Store.file("archive.json")`) and remove. Settings picker for the interval. Archive view = existing ghosts UI, searchable.
- ~80 lines. `Browser.swift`, `Settings.swift`.

#### 7. Little Arc (links from other apps open in a small floating window)
- `Links.swift` already handles incoming URLs. Instead of `newTab`, open in a second `Window("little")` sized 900×650 with a single `Tab` not in `tabs`; toolbar button "Open in Search" moves it in. Requires relaxing the one-window rule in `App.swift` (add a second `Window` scene) — keep main browser single-window.
- ~120 lines. `App.swift`, `Links.swift`, new `Little.swift`.

#### 8. Peek (link preview on ⇧-click / hover-hold)
- Same as Little Arc but modal over the page: `.sheet` with a `Page(tab:)` for a throwaway `Tab`. Escape dismisses, button promotes to real tab.
- ~60 lines after #7 (share `Little`).

#### 9. Site Search / Search engine choice
- `Google.swift` hardcodes Google. Add `Settings › Search: [Google, DuckDuckGo, Kagi, Bing, Custom]` + `@site query` bangs (map `"gh foo"` → `https://github.com/search?q=foo`). Table in `Prefs`.
- ~60 lines.

#### 10. Boosts (per-site CSS/JS)
- `Hidden.swift` already injects per-site CSS selectors at document start. Generalise: `Boost { host, css, js }` stored in `Store.file("boosts.json")`, injected via `WKUserScript` alongside veils. A tiny editor in Settings (TextEditor for CSS, TextEditor for JS). Arc's zap = existing ⌘⇧H. Arc's "replace text/colours" = skip; CSS covers it.
- ~120 lines. `Hidden.swift`, `Tab.swift`, `Settings.swift`.

### Tier 3 — polish that makes it feel like Arc

#### 11. Space colour theming
- `Space.tint: Color` → tint `Palette` accents / sidebar background per active space. `Design.swift` has all colours in one place; add a `tint` parameter.
- ~40 lines.

#### 12. Pinned tab favicons + "reset to pinned URL"
- Pins already exist. Add `Tab.pinURL` and "⌘-click pin → return to pinURL".
- ~20 lines.

#### 13. Tab search across spaces (⌘K global)
- `⌘K` currently lists open tabs; drop the space filter when the query is non-empty. Already done by #4 if you list all spaces with a space label.
- ~10 lines.

#### 14. Media controls / now-playing in sidebar
- `Float.swift` already tracks playing media for PiP. Surface a small row in `Side.swift` with title + pause (calls existing `pauseMedia()`).
- ~50 lines.

#### 15. Downloads tray in sidebar
- Downloads exist as a panel. Show last 3 in the sidebar footer. Pure UI.
- ~40 lines.

#### 16. Reader mode auto-detect + "Ask on page" (AI features)
- Arc Max features. Skip until 1–10 land. If wanted: `Reader.swift` already extracts article text → pipe to a local `ollama` or Exowatt gateway via URLSession; render answer in a sheet. Never phone home by default (upstream's privacy line).
- ~150 lines, opt-in setting.

### Explicitly not doing
- **Sync/iOS** — no backend, no mobile app. iCloud Key-Value/CloudKit sync of `spaces.json` + `session.json` is possible (~200 lines, needs App Store entitlements and a paid dev account) but not Arc-parity worth chasing first.
- **Easels/Notes** — dead in Arc too.
- **Chromium engine** — upstream policy, and the whole point.

### Suggested order to ship
1 → 2 → 4 → 3 → 6 → 5 → 9 → 7 → 8 → 10 → 11–15 → 16.
Spaces first because it unblocks 2, 5, 11 and changes the persistence shape; get the migration right once.

### Persistence shape after Tier 1
```
session.json   { tabs:[{url,title,pin,space,folder,lastSeen}], active, split:[ids] }
spaces.json    [{id,name,tint,order,profile}]
archive.json   [{url,title,space,closedAt}]
boosts.json    [{host,css,js}]
```
All `Codable`, all optional fields so upstream's writer stays readable by the fork and vice-versa on the shared fields.

---


---

## Part 1b — beyond Arc: aesthetic, customizability, MCP, sidebar widgets

Four workstreams the upstream will never do. Each is a new file (or two) plus one hook; see Part 2 for why that matters.

### A. Apple aesthetic (Liquid Glass, macOS 26)

**What Apple says (Adopting Liquid Glass, HIG › Materials, WWDC25 219):** glass is for the *navigation/control layer*, never the content layer. Sidebars float over content; content extends underneath (`backgroundExtensionEffect()`). Use system `NavigationSplitView`/toolbar first; use `.glassEffect()` only on prominent custom controls; group neighbours in `GlassEffectContainer` so they merge/morph; never glass over the web view.

**Current state:** `Design.swift` is a flat greyscale `Palette` (`pair(light, dark)`), `Side.swift` paints `Palette.ground` as an opaque background, the window is `.hiddenTitleBar` with hand-drawn traffic lights. Good bones — colour is already centralised.

**Plan (in order):**
1. **Sidebar as floating glass.** `Side.swift:84` `.background(Palette.ground)` → on macOS 26 `.glassEffect(.regular, in: .rect(cornerRadius: 12))` with 8pt inset from the window edge; `Stage` extends under it via `.backgroundExtensionEffect()`. `#available(macOS 26, *)` fallback = `Material.sidebar` (`.background(.ultraThinMaterial)`) on 14/15. ~30 lines, one file.
2. **Omnibox as a glass capsule.** The address field (`Omnibox.swift`) floats over the page top when editing: `GlassEffectContainer { field; suggestions }` so they morph into one shape. ~40 lines.
3. **Tab rows.** Selected-tab `wash` → `.glassEffect(.regular.tint(space.tint.opacity(0.3)).interactive())`. Hover uses the same with lower opacity. ~20 lines in `Side.swift`/`TabBar.swift`.
4. **Motion.** Adopt `.animation(.smooth)` / `.spring(duration: 0.25)` on tab reorder + space switch; use `matchedGeometryEffect` for the sliding selection ("the grey slides") which already exists conceptually.
5. **SF Symbols everywhere** (`Icons.swift` already exists) with `.symbolEffect(.bounce)` on state changes (download done, pin added).
6. **Vibrancy for text** on glass: `.foregroundStyle(.primary/.secondary)` instead of fixed `Palette.ink/muted` so it stays legible on tinted glass. Do this by making `Palette` return semantic colours when glass is on.
7. **Respect Reduce Transparency / Increase Contrast** — system handles it if you use system materials; test both.

Ceiling: glass requires macOS 26 SDK → Xcode 26 in `build.sh`; keep `Package.swift` platform at `.v14` and gate with `#available`.

### B. Customizability

Arc has almost none; Vivaldi/Zen have too much. Aim: **one JSON file + one Settings pane**, no plugin system.

1. **Theme file.** `Palette` becomes `Theme: Codable { ground, ink, muted, faint, hairline, wash, hover, accent, radius, glass: Bool, font: String? }` loaded from `Store.file("theme.json")`, defaulting to today's values. `Design.swift` reads `Theme.current`. Settings › Appearance gets colour wells + "Export/Import theme". Space tints (Part 1 #11) override `accent`. ~120 lines.
2. **Layout knobs** in `Prefs`: sidebar width, tab density (compact/comfortable), show favicons vs letters, pin grid columns, glass on/off, toolbar items. All `@AppStorage` on `Store.settings` (already the pattern in `Prefs.swift`). ~60 lines.
3. **Keyboard remap.** `Shortcuts.json: [command: keyEquivalent]`; `App.swift` `.commands` reads `Shortcut.for("newTab")` instead of literal `"t"`. Settings › Keyboard = table. ~80 lines.
4. **Custom CSS for the browser UI itself** — skip; SwiftUI can't be styled by CSS, and the theme file covers 90%. Say no.
5. **Per-site boosts** (Part 1 #10) cover page-side customisation.
6. **New-tab page** = the widget board (see D) — no separate "start page" concept.

### C. MCP integration — **Felipe's, kept here for context**

Collin is not doing this section (nor Jev or Stagehand work). Two directions; do the server first, it is the one nothing else provides on WebKit.

#### C1. Search as an MCP **server** (agents drive the browser)
Chrome DevTools MCP and Playwright MCP exist for Chromium; nothing for a WebKit browser with your real sessions/cookies. That is the differentiator: Claude Code / phi drive *your* logged-in browser.

- **SDK:** `modelcontextprotocol/swift-sdk` (0.11.x, spec 2025-11-25). Upstream forbids deps; the fork allows exactly this one — record it in the patch manifest (Part 2). Alternative with zero deps: hand-write JSON-RPC over stdio (~300 lines) — not worth it; take the dep.
- **Transport:** in-app **Streamable HTTP** on `127.0.0.1:<port>` via `StatelessHTTPServerTransport` bridged to a tiny `Network.framework` `NWListener` (no Vapor). Bearer token generated at first launch, stored in keychain via existing `Vault`, shown in Settings › MCP with a "Copy config for Claude Code / phi" button. Also ship `search --mcp-stdio` (a `CommandLine.arguments` check in `App.swift` that runs the server against a hidden window) for clients that only speak stdio.
- **Tool surface** (mirror Playwright MCP names so agent skills written for it transfer):

  | Tool | Impl |
  |---|---|
  | `browser_tabs` (list/select/new/close) | `Browser.tabs`, `select`, `newTab`, `close` |
  | `browser_navigate`, `browser_navigate_back` | `tab.web.load` / `goBack` |
  | `browser_snapshot` | inject a11y-tree script → JSON with `ref` ids (reuse the ref→selector map for click/type) |
  | `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key` | `evaluateJavaScript` on the ref'd element |
  | `browser_evaluate` | `callAsyncJavaScript` |
  | `browser_take_screenshot` | `takeSnapshot(with:)` → PNG base64 |
  | `browser_wait_for` | poll `evaluateJavaScript` |
  | `read_page` (Search-specific) | `Reader.swift` extraction → markdown; cheapest token path |
  | `browser_console_messages` | `WKScriptMessageHandler` shim capturing `console.*` |
  | resources: `search://tabs`, `search://history?q=`, `search://bookmarks` | read-only |

- **Safety:** all tools run on `MainActor` via the existing `Browser`; token required; per-call "agent is driving" banner in the sidebar (reuse `announce()`); `private` tabs are never exposed; a setting to require click-to-approve for `browser_evaluate` on hosts in a denylist (banks). Never expose `Vault`.
- **Files:** `MCP/Server.swift` (tools), `MCP/Snapshot.swift` (a11y script + ref map), `MCP/Listener.swift` (NWListener bridge), Settings pane. ~700 lines total. Hooks into upstream files: one `if CommandLine.arguments.contains("--mcp-stdio")` in `App.swift`, one `Task { await MCP.start() }` at launch.

#### C2. Search as an MCP **client** (an agent in the sidebar)
- A sidebar widget (see D) hosting a chat with a model that has (a) the C1 tools bound locally — no HTTP round trip — and (b) whatever external MCP servers you configure (`mcp.json`, same shape Claude Code uses, so you paste your existing file).
- **Model access:** BYO endpoint — `Settings › AI: base URL + key`, OpenAI-compatible or Anthropic messages. Default to Exowatt gateway for you; ship with nothing configured (upstream's privacy stance: nothing leaves the Mac unless you set it up).
- Swift SDK gives `Client` + `HTTPClientTransport`/`StdioTransport` for the external servers — same dep as C1.
- Prompt = page context from `read_page` + user text; tool loop until done. ~500 lines. Do after C1 and D ship; it needs both.
- "Ask on page" from Part 1 #16 collapses into this.

### D. Sidebar widgets

**Constraint (researched):** WidgetKit widgets *cannot* be embedded in your own app — they render in the system's widget surfaces only. ExtensionKit (`EXHostViewController`) can host third-party remote UI but is heavy. So: a home-grown board of two widget kinds, which is what Vivaldi did (native dashboard widgets + Web Panels).

**Model:**
```swift
enum WidgetKind: Codable { case web(URL), note, todo, clock, calendar, media, downloads, agent, tabsPreview }
struct WidgetSpec: Codable, Identifiable { id, kind, height: CGFloat, collapsed: Bool, space: UUID? }
```
Persisted in `Store.file("widgets.json")`. `Side.swift` becomes `VStack { pins; tabs; Divider; WidgetBoard }` where `WidgetBoard` is a `ForEach(specs)` of resizable cards, reorderable with `.onMove`/`.draggable` (SwiftUI drag on macOS 14+), each in a `DisclosureGroup`. Widgets can be per-space or global (`space == nil`).

**Widget kinds, ordered by value/cost:**
1. **Web panel** (Vivaldi Web Panels) — a `Tab` not in `tabs`, rendered with the existing `Page(tab:)` at sidebar width with a mobile UA (`config.applicationNameForUserAgent` = iPhone Safari string). Slack, Todoist, Calendar, ChatGPT, anything. This one widget covers 80% of asks. ~80 lines because `Tab`/`Page` already exist.
2. **Note** — `TextEditor` bound to a file per widget. ~30 lines.
3. **Now playing** — `Float.swift` already knows the playing tab; title + play/pause. ~40 lines.
4. **Downloads** — existing panel data, last 3 rows. ~30 lines.
5. **Todo** — list of `{text, done}`; ~60 lines.
6. **Clock / calendar** — `TimelineView(.everyMinute)`; calendar via `EventKit` (needs the Calendars entitlement + a prompt). ~80 lines.
7. **Agent** — the C2 chat. Felipe's; ships when C2 does.
8. **Tabs preview** — thumbnails of the other spaces' tabs (`Tab.cover` snapshots exist for sleep). ~50 lines.
9. **HTML widgets** — user-authored: a folder in `Application Support/Search/Widgets/<name>/index.html` rendered in a web panel with a tiny `window.search` JS bridge (`tabs.list`, `tabs.open`, `page.text`) via `WKScriptMessageHandler`. This is the "customisable" escape hatch and needs no plugin API design. ~120 lines.

**Layout:** cards use `.glassEffect` on 26 (see A) and `Material` before; height drag handle at the bottom edge; ⌥-click title to collapse; right-click → remove / move to top / per-space toggle. Empty new-tab page shows the same board full-width (B.6).

**Order:** D1 web panel first (unlocks Slack/Calendar immediately), then D2/D3/D4 (trivial), then the board's drag/resize polish, then D9. D7 lands whenever Felipe's C2 does.

---

## Part 2 — keeping the fork in sync with upstream

### What the research actually says (and what the dev crowd repeats)

I could not pull raw X/Twitter threads (search returns no post bodies), so this is the consensus from git-scm docs, the kernel maintainer guide, GitHub docs, Zen/Waterfox's setups, and the advice that circulates in dev threads. It boils down to six things:

1. **Never work on the branch that mirrors upstream.** `main` = fast-forward-only mirror. Your work lives elsewhere. Everyone says this; everyone who skips it ends up with a `main` that can't fast-forward and a fork that can't be diffed.
2. **Treat your changes as a patch stack, not a branch.** The kernel/git-workflows guidance: rebase *private* stacks, merge *shared* history. Keep the stack small, ordered, and explained. Zen Browser does this literally — Zen code lives in `src/zen/`, Firefox edits are exported patch files, an upstream bump is "refresh patches, fix conflicts, test." Waterfox does the opposite (full-tree fork) and pays for it with heavier merges. **Do the Zen thing: new files in your own directory, minimal patches to theirs.**
3. **Use GitHub's own `merge-upstream` endpoint, not a marketplace action.** `POST /repos/{owner}/{repo}/merge-upstream {branch}` is what the "Sync fork" button calls. It fast-forwards and returns `409` on divergence instead of silently doing something. Third-party "sync fork" actions (wei/pull, aormsby/Fork-Sync…) were the 2020–2023 answer; the recommendation now is the native endpoint, and if you must use an action, pin it to a SHA.
4. **`git rerere`** — turn it on. Same conflict shape on the next rebase → git replays your resolution. One config line, free.
5. **`jj` (Jujutsu) if you find yourself rebasing the stack often.** `jj rebase -s <bottom> -d main` moves the whole stack; conflicts are stored in the commits rather than stopping the rebase; change-ids survive rewrites. This is the tool people on X are actually excited about for exactly this job. Optional — git + rerere is enough until the stack passes ~15 patches.
6. **Let an agent do the mechanical rebase, gated by CI + human review.** The current practice: a scheduled job runs Claude Code / a `rebaser` skill in a worktree, resolves conflicts *in the patch that owns the behaviour* (never "ours"/"theirs" wholesale), builds, and opens a PR. Anthropic's own power-user docs show a recurring `/babysit` that rebases and shepherds PRs. Caveat everyone repeats: don't auto-merge, and don't let it pick sides mechanically. Below is how to wire it for this repo.

Plus the one thing specific to this upstream: the author squashes releases into a single commit. Rebase onto a squashed 1.1 will replay your stack against one giant diff; conflicts concentrate in `Browser.swift`. The Zen-style layout is what keeps that survivable.

### Branch layout
```
upstream/main   — never touched, fetched only
main            — mirror of upstream/main (ff-only, synced by the merge-upstream endpoint)
fork            — release branch = main + the patch stack (rebased while private, merged once shipped)
feat/<name>     — one branch per Part-1/1b item while it's in progress
```
Build/ship from `fork`. `git diff main..fork` is always "exactly what the fork adds"; `git range-diff` between two rebases shows what the rebase changed.

### Repo layout (Zen-style)
```
Sources/Search/           upstream's files — touch as little as possible
Sources/Search/Fork/      everything yours: Spaces.swift, Split.swift, Widgets/, MCP/, Theme.swift, Little.swift …
PATCHES.md                the manifest (below)
```
SwiftPM compiles everything under `Sources/Search` recursively, so a subfolder costs nothing.

### Rules that keep rebases cheap
1. **New files over edited files.** Anything upstream doesn't have can't conflict. `extension Browser` / `extension Tab` in your own files reach their internals (same module) without editing theirs.
2. **Hooks are one-liners.** Where an upstream file must change (`Browser.select`, `Session.Shape`, `App.commands`, `Side.body`), add a single call into your code — `Fork.hook(...)` — not logic.
3. **Additive optional `Codable` fields only** so `session.json` round-trips both directions.
4. **Match their style** (why-comments, Swift 5 mode, no force-unwraps) so any patch can be sent upstream and then *deleted* from the stack. Upstreaming is the cheapest maintenance there is.
5. **Don't rename their identifiers**, don't reformat their files. Conflicts come from touched lines.
6. **One dependency, documented.** `modelcontextprotocol/swift-sdk` breaks their "no deps" rule; it lives only in `Package.swift` (one conflict-prone line) and `Fork/MCP/`. Never let it leak into upstream files.

### PATCHES.md — the manifest
One row per patch that touches an upstream file. This is the thing the kernel guide calls "treat the stack as a product."
```
| patch | touches | why | upstream status | drop when |
| spaces-hook | Browser.swift:select, Session.swift:Shape | filter tabs by space | not sent (they'd say no) | never |
| search-engine | Google.swift | engine picker | PR #NN open | merged |
| updater-off | Updater.swift | don't self-replace with upstream | fork-only | never |
```
Update it in the same commit as the patch. When a row's "drop when" fires, delete the patch and the row.

### Sync procedure (what the automation does, and what you do by hand when it can't)
```sh
git config rerere.enabled true       # once
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout fork
git rebase main                      # or: git merge main  — see "rebase vs merge"
swift build 2>&1 | grep -E "error|warning: .*Sources/Search/" ; ./build.sh
git range-diff origin/fork...fork    # eyeball what the rebase changed
git push --force-with-lease origin fork
```
**Rebase vs merge:** rebase while nobody but you pulls `fork` (linear, diffable, patch-stack semantics). Switch to `git merge main` with a `Merge upstream 1.x` commit the day someone else is on it — force-pushing a shipped branch breaks their pull. Both work with rerere.

### Automation

**Layer 1 — mirror `main` (native endpoint, zero third-party code).** `.github/workflows/sync-main.yml`:
```yaml
on: { schedule: [{cron: "17 */6 * * *"}], workflow_dispatch: {} }
permissions: { contents: write }
jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - env: { GH_TOKEN: "${{ github.token }}" }
        run: gh api --method POST "repos/${{ github.repository }}/merge-upstream" -f branch=main
```
A `409` here means you accidentally committed to `main`; fix that, not the workflow. Scheduled workflows only fire from the default branch and are disabled on fresh forks — enable Actions once.

**Layer 2 — rebase `fork`, build, open a PR (fails loudly on conflict).** `.github/workflows/sync-fork.yml`, triggered by Layer 1 success:
```yaml
on: { workflow_run: { workflows: ["sync"], types: [completed] }, workflow_dispatch: {} }
permissions: { contents: write, pull-requests: write }
jobs:
  rebase:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@<sha>
        with: { ref: fork, fetch-depth: 0 }
      - run: |
          git config user.name bot && git config user.email bot@users.noreply.github.com
          git fetch origin main
          git checkout -b sync/$(date +%F) fork
          git rebase origin/main || { echo "::error::conflict — run the agent step or resolve by hand"; exit 1; }
          swift build
          git push origin HEAD
          gh pr create --base fork --title "Sync upstream $(date +%F)" \
            --body "$(git range-diff origin/fork...HEAD | head -200)"
        env: { GH_TOKEN: "${{ github.token }}" }
```
Green = a PR to click. Red = conflict → Layer 3 or you.

**Layer 3 — agent conflict resolution (opt-in, still PR-gated).** On Layer 2 failure, a job checks out the conflicted rebase in a worktree and runs Claude Code headless with a fixed prompt:
> Rebase `fork` onto `origin/main` is stopped on a conflict. Read `PATCHES.md`. Resolve each conflict inside the patch that owns the behaviour, preserving both upstream's change and the fork's intent — never take a whole side. Run `swift build`; fix compile errors the same way. Continue the rebase until done. Do not push; do not merge. Write a summary of every resolution to `SYNC-NOTES.md`.

Then the job pushes the branch and opens the PR with `SYNC-NOTES.md` as the body. You review the range-diff, not the code. Needs `ANTHROPIC_API_KEY` (or the Exowatt gateway) in repo secrets and `claude -p` on the runner. Keep `fork` protected so nothing merges without a human. Skip this layer until the first conflict actually happens; two lines of rerere may make it unnecessary.

**Layer 4 — release on tag.** `v1.0-fork.N` tag → `./build.sh release dmg` → GitHub Release with `Search.dmg` + a `VERSION`/appcast file that the fork's `Updater` reads (below).

### Releasing your build
- `./build.sh release dmg` gives an ad-hoc-signed DMG. Fine for your own Macs (right-click → Open once). A Developer ID ($99/yr) gets you notarisation + a working self-updater.
- **Updater.swift** polls `officecommun.com` and verifies *their* signature. Untouched, a fork build will one day replace itself with upstream 1.1 and drop every feature. Patch: point the feed at your GitHub Release asset and your signing identity — or a one-line early return until you have a Developer ID. This is a permanent row in `PATCHES.md`.
- **Bundle id + app name**: change both in `build.sh` so the fork and upstream coexist (separate keychain items, separate `Application Support` folder — `Store.folder` derives from the bundle). Otherwise they fight over `session.json`.
- Tag `v1.0-fork.1`, `v1.0-fork.2` … so the upstream base is visible in the tag.

### Weekly checklist (5 min)
1. Layer 2 PR green → skim the range-diff → merge.
2. `swift build` warnings introduced by the fork = 0.
3. Skim upstream issues/PRs. If they start Spaces or split view, stop yours and wait — theirs wins the rebase. Their CONTRIBUTING asks for an issue before big PRs; file one for anything you'd like to upstream (search engine picker, pin-URL reset, auto-archive, media row are plausible; multi-window and MCP are not).
4. Anything merged upstream → delete the patch, delete the manifest row.
