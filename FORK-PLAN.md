# Fork plan: Arc-class features

Fork: `copper-browser/Copper` · upstream: single-author, one squashed commit, v1.0.

Ground truth from the code (as of fork):

- `Browser.swift` (1.9k lines) is the model: `@Published tabs: [Tab]`, `activeID`, pins, ghosts, find, omnibox, passwords — everything.
- `Tab.swift` owns one lazy `WKWebView`; sleeps after 30 min; restores from `Session.swift` (`session.json`: flat `[Entry{url,title,pin}]` + `active`).
- `App.swift` → single SwiftUI `Window("browser")`, "one window, on purpose". `Extensions.swift:801` also folds new windows into tabs.
- `Side.swift` / `TabBar.swift` = vertical / horizontal tab UIs. `Stage.swift` = the page area (single `WebStage`).
- `Store.swift` = files under `~/Library/Application Support/Copper/`, `UserDefaults` at `Store.settings`.
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
- `Links.swift` already handles incoming URLs. Instead of `newTab`, open in a second `Window("little")` sized 900×650 with a single `Tab` not in `tabs`; toolbar button "Open in Copper" moves it in. Requires relaxing the one-window rule in `App.swift` (add a second `Window` scene) — keep main browser single-window.
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

### C. MCP integration

Two directions; do the server first, it is the one nothing else provides on WebKit.

**Status (Felipe's lane):** server, Jev mode, CLI and client shipped (see COLLIN.md). **agent links shipped** — `Fork/MCP/Link.swift` + `LinkWire.swift`: Copper dials out to configured agents apps and serves these same tools to granted bots (Settings › Agents, `copper link …`, `docs/agents.md`).

#### C1. Copper as an MCP **server** (agents drive the browser)
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
  | `read_page` (Copper-specific) | `Reader.swift` extraction → markdown; cheapest token path |
  | `browser_console_messages` | `WKScriptMessageHandler` shim capturing `console.*` |
  | resources: `search://tabs`, `search://history?q=`, `search://bookmarks` | read-only |

- **Safety:** all tools run on `MainActor` via the existing `Browser`; token required; per-call "agent is driving" banner in the sidebar (reuse `announce()`); `private` tabs are never exposed; a setting to require click-to-approve for `browser_evaluate` on hosts in a denylist (banks). Never expose `Vault`.
- **Files:** `MCP/Server.swift` (tools), `MCP/Snapshot.swift` (a11y script + ref map), `MCP/Listener.swift` (NWListener bridge), Settings pane. ~700 lines total. Hooks into upstream files: one `if CommandLine.arguments.contains("--mcp-stdio")` in `App.swift`, one `Task { await MCP.start() }` at launch.

#### C2. Copper as an MCP **client** (an agent in the sidebar)
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
7. **Agent** — the C2 chat. Ships when C2 does.
8. **Tabs preview** — thumbnails of the other spaces' tabs (`Tab.cover` snapshots exist for sleep). ~50 lines.
9. **HTML widgets** — user-authored: a folder in `Application Support/Copper/Widgets/<name>/index.html` rendered in a web panel with a tiny `window.copper` JS bridge (`tabs.list`, `tabs.open`, `page.text`) via `WKScriptMessageHandler`. This is the "customisable" escape hatch and needs no plugin API design. ~120 lines.

**Layout:** cards use `.glassEffect` on 26 (see A) and `Material` before; height drag handle at the bottom edge; ⌥-click title to collapse; right-click → remove / move to top / per-space toggle. Empty new-tab page shows the same board full-width (B.6).

**Order:** D1 web panel first (unlocks Slack/Calendar immediately), then D2/D3/D4 (trivial), then the board's drag/resize polish, then D9, then D7 with C2.

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

**Layer 4 — release on tag.** `v1.0-fork.N` tag → `./build.sh release dmg` → GitHub Release with `Copper.dmg` + a `VERSION`/appcast file that the fork's `Updater` reads (below).

### Releasing your build
- `./build.sh release dmg` gives an ad-hoc-signed DMG. Fine for your own Macs (right-click → Open once). A Developer ID ($99/yr) gets you notarisation + a working self-updater.
- **Updater.swift** polls upstream's site and verifies *their* signature. Untouched, a fork build will one day replace itself with upstream 1.1 and drop every feature. Patch: point the feed at your GitHub Release asset and your signing identity — or a one-line early return until you have a Developer ID. This is a permanent row in `PATCHES.md`.
- **Bundle id + app name**: change both in `build.sh` so the fork and upstream coexist (separate keychain items, separate `Application Support` folder — `Store.folder` derives from the bundle). Otherwise they fight over `session.json`.
- Tag `v1.0-fork.1`, `v1.0-fork.2` … so the upstream base is visible in the tag.

### Weekly checklist (5 min)
1. Layer 2 PR green → skim the range-diff → merge.
2. `swift build` warnings introduced by the fork = 0.
3. Skim upstream issues/PRs. If they start Spaces or split view, stop yours and wait — theirs wins the rebase. Their CONTRIBUTING asks for an issue before big PRs; file one for anything you'd like to upstream (search engine picker, pin-URL reset, auto-archive, media row are plausible; multi-window and MCP are not).
4. Anything merged upstream → delete the patch, delete the manifest row.
