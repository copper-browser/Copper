# Settings

*How the Settings panel is built and how to change it without breaking it: pages and groups, the
controls and what they promise the keyboard and VoiceOver, the search index, the questions
Settings asks before something it can't undo, the rules for a narrow window, what a test run
does differently, and the checks that measure all of it. Files: `Sources/Search/Settings.swift`,
`Sources/Search/Plate.swift` and `Sources/Search/Fork/Settings*.swift`. How the current shape
came about is in [plans/2026-10-07-move-in-and-settings.md](plans/2026-10-07-move-in-and-settings.md).*

## The panel

⌘, sets `browser.tuning` and draws `SettingsPanel` (`Settings.swift`) over the window: a rail of
pages under a search field on the left, one page on the right. It takes the room the window
gives it (`SettingsPanel.span`): 600 to 920 points wide and 440 to 700 tall, 80 points in from
the window's edges, down to 24 in a small window. The rail is 220 points wide, or 190 when the panel is narrower
than 760. A browser window can't be smaller than 640×420 (`App.swift`, `Fork/Windows.swift`),
which makes the narrowest panel 600 points and the narrowest page column 345 points. Every page
has to fit that column. The page last shown is kept in `settings.page`.

While Settings is open, the app's key monitor asks `SettingsKeys.take`
(`Fork/SettingsBench.swift`) first:

- ⌘F puts the keyboard in the search field.
- ⌘W, with no other modifier, closes Settings, not the tab behind it.
- Escape clears the query, and on an empty query closes Settings.
- ↑ ↓ ↩ walk and pick search results.
- A letter typed while no field has the keyboard starts a search.

## Pages and groups

`SettingsPanel.Page` (`Settings.swift`) lists the pages in upstream's order, which is also what
`settings.page` stores. The rail draws them in four groups, in `Page.railOrder`
(`Fork/SettingsIndex.swift`):

| Group | Pages, in rail order | Drawn in |
|---|---|---|
| Browsing | General (with Downloads), Tabs, Spaces, Extensions (with Addons) | `Settings.swift` (`general`, `downloads`, `tabs`); `Fork/SpacePage.swift`; `ExtensionsUI.swift` with `Fork/ExtensionsManager.swift` and `Fork/Addons/AddonUI.swift` (`AddonsPage`) |
| AI & agents | Intelligence (with Voice), Agents | `Fork/SettingsFork.swift` (`IntelligencePage`, `AgentsPage`); `Fork/Voice/VoiceSettings.swift` (`VoicePage`) |
| Data & privacy | Passwords, Privacy | `Settings.swift` (`passwords`, `privacy`) with `Fork/CredentialsSettings.swift` and `Fork/PrivacySettings.swift` |
| Copper | Cloud, About (with Updates) | `Fork/Cloud/CloudSettings.swift`; `Settings.swift` (`about`) with `Fork/SettingsFork.swift` (`UpdatesPage`) |

Downloads, Labs, Voice, Addons and Updates were pages of their own until October 2026; a stored
`settings.page` naming one opens General. To open Settings at a section of a page, use
`browser.openSettings(.intelligence, at: "voice.enabled")`: the anchor is landed on as a search
result is.

Each page has a title, an icon, a one-line `blurb` under its title, and page-level `keywords`
for search (`Fork/SettingsIndex.swift`).

A new page needs a case in `Page` (title and icon), a place in `Page.group` and `railOrder`, a
`blurb` and `keywords`, a branch in the panel's `switch page`, and index rows (below). Changes to
`Settings.swift` or `Plate.swift` are changes to upstream files, so they get a row in
`PATCHES.md`. New code goes in `Sources/Search/Fork/`.

## How a page is built

A page is a column of sections. Each piece reads `settingsLook` from the environment, so the
same `Line` looks like Settings inside the panel and like itself everywhere else (the Passwords
list, the Downloads panel).

- **`SettingsSection(title, note:, carded:)`** (`Fork/SettingsLook.swift`): a title, one `Card`
  of rows, and an optional sentence under it. Pass `carded: false` when the content brings its
  own cards, so they are not boxed twice.
- **`Line(title, detail) { control }`** (`Plate.swift`): what it is, a plain sentence, and the
  control at the right. In Settings, a control too wide to sit beside its words goes under them
  (`ViewThatFits`), and a detail is never cut off. A `Line` also hands its title to the control
  inside it as `controlLabel`, which is how a switch gets its name.
- **`SettingsAdvanced(anchor, holds:)`** (`Fork/SettingsLook.swift`) folds rows most people never
  touch at the foot of a card. Each folded row's index entry takes `fallback: anchor`, and a search
  for one of `holds` opens the fold before the page scrolls (`settingsPending`).
- **`Rule()`** between rows, **`SettingsNote`** for a sentence under a section,
  **`SettingsHeader`** for the page title and blurb.
- **Colours and sizes:** `SettingsInk` (rail, content, card, edge, secondary text) and
  `SettingsMetrics`, both in `Fork/SettingsLook.swift`.

## The controls and their contract

Copper's own controls are drawn shapes, not AppKit controls, so each one has to say what it is.
`Switch`, `Segmented` and `Pill` live in `Settings.swift`; `Quick`, the small text action inside
a row (Show, Copy, Remove), lives in `Plate.swift`. The shared pieces are in
`Fork/SettingsControls.swift`. The contract every control on a Settings page keeps:

| | Role and value | Keyboard |
|---|---|---|
| `Switch(on:, label:)` | one element, toggle trait, value "On" or "Off" | a Tab stop; Space or Return flips it |
| `Segmented(options:, selection:, label:)` | a group whose value is the chosen option; each choice a button, the chosen one selected | a Tab stop; ← → move one step and stop at the ends, as the Mac's segmented controls do |
| `Pill(title)` | a button | a Tab stop; Space presses it |
| `Quick(title)` | a button | a Tab stop |
| text fields | the field's own | `.settingsField()` (`Fork/SettingsField.swift`) draws the wash and an ink edge while focused, because plain-style fields draw no ring of their own |

- **Every control has a name.** `SettingsControlRules.name(given:row:)`: the label passed where
  the control is made wins, else the title of the `Line` it sits in, else nothing (which the
  sweep below reports). An outer `.accessibilityLabel` on a `Switch` does not work: the switch's
  own label overrides it. Pass `label:` instead. A `Pill` whose title doesn't say what it acts
  on ("Clear…") gets an `.accessibilityLabel` ("Clear history").
- **Tab reaches every enabled control** when Keyboard navigation is on in System Settings
  (`settingsFocusable`, or `settingsFocusRing` for a `Button`, which is focusable already).
- **The focus ring** is Settings' own (`SettingsFocusRing`): the control's shape, 3 points
  outside it, in ink, and nothing while unfocused. The system's blue halo is turned off.
- **A row that can't apply here is not drawn** (Swipe between spaces with tabs across the top,
  Voice's options while voice is off); search lands on the row that brings it, through the
  entry's `fallback`. A control that is shown but can't act right now (set by Copper Cloud, a
  test run) is `.disabled`, with the reason in the row's detail. Disabled, not
  `.allowsHitTesting(false)`, so Tab and VoiceOver skip it too.
- **The close button** is named "Close Settings". Icon-only buttons carry a label.

Each of these controls also writes itself into `SettingsControlLedger` as it draws — kind, page,
name, value, whether Tab can reach it, whether it is disabled — but only in a test run. SwiftUI
builds its accessibility tree only for a real accessibility client, so a probe with none asks
the controls instead.

**`./bench --world W settings ax sweep`** opens every page in turn (starting one page over, so
the first page draws too) and lists every control with its name and reachability. It answers
`ok: false` with the `unnamed` and `unreachable` controls if any exist. Run it with a saved
password in the world as well as a clean one: some rows (Agent access) only draw with data.
`settings ax` alone, `ax focus`, `ax controls` and `ax raw` read the window's real accessibility
tree in process, with no grant needed.

## Search and the index

Search reads only `SettingsIndex` (`Fork/SettingsIndex.swift`): one entry per page, then one per
row, each with its page, section, title, subtitle, keywords and the anchor search lands on. The
matcher (`SettingsMatcher`, `Fork/SettingsSearch.swift`) folds case and diacritics and scores
each query word against each word of a field: exact, then prefix, then inside a word, then one
typo (two in words of nine letters or more; only in words of five or more, first letter kept),
then the letters in order. Title outweighs keywords, which outweigh page and section, which
outweigh the subtitle. Every query word has to land somewhere. Two words typed together match
only whole, from the start, or with one slip.

To add a row search can find:

1. Mark the row where it is drawn: `.settingsAnchor("page.thing")`, or
   `.settingsAnchor("page.thing", card: true)` for a whole card. A card lands by a mark 36
   points above its top edge, so its section title stays in view under the page header; a row
   lands about a fifth of the way down (`SettingsAnchor.land`, `Fork/SettingsLook.swift`).
2. Add an entry to `SettingsIndex.rows`, in page order:
   `e(.page, "Section", "Title", "Subtitle", ["other", "words", "people use"], "page.thing")`.
   - `fallback: "page.card"` when the row isn't always drawn (a password-manager row while its
     vault is locked); search then lands on the card or section that holds it.
   - `toggle: pref(\.someBool)` for a boolean setting that can be flipped right in the results.
3. Keywords are the words people type, not the words on screen: synonyms, other browsers'
   names for it, the shorthand ("pw", "mic"). Check them with
   `./bench --world W settings search "ask before download" --table`, which prints one line per
   result with the matched letters bracketed.
4. Run **`./bench --world W settings index check`**. It opens every page and compares what was
   drawn with the index. It fails on an entry whose anchor (or fallback) isn't drawn, on an
   anchor drawn with no entry, and on a page with no rows. `viaFallback` lists the entries that
   landed on their fallback. A page change that adds a row without an entry, or drops a row an
   entry points to, fails here.

The other search verbs: `settings search QUERY` (JSON), `settings select N` and `settings pick N`
(as ↑/↓ and Return would), `settings toggle N` (flip result N's switch), `settings state`.

## Questions before what can't be undone

Clear history, Sign out of everything, New token…, Delete space and Remove extension ask first.
So do revoking a link or pairing code, removing an agents app, disconnecting from Copper Cloud
and deleting cloud history. The rules:

- The question says exactly what will happen ("Every address you have been to goes from this
  Mac and from Copper Cloud, for every Mac signed in as you. This can't be undone.",
  `Fork/PrivacySettings.swift`).
- The button that does it is `.destructive` and named for what it does ("Sign Out of
  Everything"), and Cancel is the cancel role.
- Something cheap to redo stays one click: Clear cache doesn't ask.

There are two ways to ask, and both can be answered by a test:

- **An AppKit alert:** `TestConfirm.present(alert, kind:, window:, decide:)`
  (`Fork/SettingsControls.swift`), used by Delete space (`Fork/SpacesUI.swift`) and Remove
  extension (`Fork/ExtensionsManager.swift`). For a person it is a sheet on the window, as
  always.
- **A SwiftUI `.confirmationDialog`** on a page, for the rest. SwiftUI shows it as an alert sheet; in a headless
  test run with Settings open, the headless alert hook (`Fork/Headless.swift`) hands that sheet
  to `TestConfirm.adopt` instead of declining it, as it declines every other alert.

In a headless test run (`TestConfirm.holds`) the question waits for the bench, rather than
being put on a window nobody can see. In a windowed test run, an AppKit alert still goes up as a
sheet, and answering it presses the sheet's own button; a SwiftUI dialog is held only headless. **`./bench --world W settings confirm`** shows the question that is up (kind, message,
detail, buttons); `settings confirm answer CHOICE` presses a button by number, title or the start
of its title; `settings confirm selftest` puts up a dialog, holds it, answers it and checks that
the button's action ran. A new destructive action should be checked this way: cancel, then
confirm, then read the result.

## Narrow windows

Settings has to work at its smallest: a 345-point page column.

- **Nothing scrolls sideways.** The page's scroll view is vertical only, so anything wider than
  the column is cut off rather than scrolled to. Rows of things wrap (`SettingsFlow`,
  `Fork/SettingsSearchUI.swift`), grids are adaptive (Spaces' icons at 34 points, pictures at
  54), a side-by-side layout stacks when there is no room (`SpaceSplit` in `Fork/SpacePage.swift`,
  `ViewThatFits` in `Fork/ExtensionsManager.swift`), and `Line` puts a wide control under its
  words.
- **No fixed widths wider than the column.** A fixed column count, a fixed-width HStack or a
  large leading indent is what pushed Spaces and Extensions past the panel before.
- **Text wraps.** Settings never truncates a sentence; give long values `.fixedSize(horizontal:
  false, vertical: true)` rather than a line limit.
- **The rail fades** at its lower edge (`SettingsRailFade`), so a short window shows there are
  more pages.

Check a change with **`./bench --world W settings browse picture PAGE OUT.png 345 light`** (and
`dark`, and a wide width), which draws the whole page at that column width — for the pages
that are views of their own: spaces, extensions, voice, cloud, updates, intelligence, agents and
labs — and
**`settings browse scroll [top|bottom|next|PX]`** on the open page, which reports `sideways`
(the page is wider than its column) and `horizontalScroller`. Both must be false. Do it at a
640×420 window (a headless world started with `SEARCH_HEADLESS_SIZE=640x420`), light and dark, with real-looking data (an installed extension, a saved
password, a long space name).

## Panels and sheets

A folder chooser or save panel opened from Settings is a sheet on its window, not an app-modal
panel that freezes every window: `SettingsPanels.present(panel, on: window, done:)`
(`Fork/SettingsBrowse.swift`). It is app-modal only when there is no visible window to attach
to. Downloads' Change…, Ask where to save, a space's picture and Load Unpacked use it. One
exception today: Passwords › Import still runs its open panel with `runModal`
(`Browser.importPasswords`).

## What a test run does differently

A test run (`Store.testing`: any `SEARCH_PROBE`, any development build, anything run from the
build folder) must never reach the person at the Mac. Settings' seams, all decided at runtime and
each off outside a test world (`DataSettingsTests.probeSeamsAreOffOutsideATestWorld`):

| What | In the browser somebody uses | In a test run | Where |
|---|---|---|---|
| Copy (tokens, prompts, configs) | the general pasteboard | a pasteboard of the world's own, `copper.probe.<world>`, in a named world with the bench on | `SettingsActions.copy` (`Fork/SettingsActions.swift`) |
| Open (a file, an address, the editor) | `NSWorkspace.open` | noted, never opened; read back with `bench about clipboard` or `bench ai clipboard` | `SettingsActions.open` |
| Make default | asks macOS | refused; the row says "Not in a test run — links stay with the browser you use" and the button is disabled | `Links.refusesDefault`, `Links.becomeDefault` (`Links.swift`) |
| `update.log` | `~/Library/Logs/Copper/update.log` | `update.log` in the world's folder | `Updates.logFile(world:folder:home:)` (`Fork/Updates.swift`) |
| WebKit's spelling switches | written to the app's defaults | set in the launch's volatile domain, never written to disk | `Preferences.tellWebKit` (`Prefs.swift`) |
| Downloads folder | the chosen folder, or ~/Downloads | the world's `Downloads`, or a chosen folder only if it is inside the world or under /tmp | `Prefs.swift`, `Preferences.testFolder` |
| Ask where to save | a save sheet | answered by `bench settings browse ask PATH\|cancel\|folder` | `DownloadAsk` (`Fork/SettingsBrowse.swift`) |
| Terminal-agent setup | your home and bin folders | `SEARCH_SETUP_HOME`, else the world's `setup-home` | `Setup.testHome` (`Fork/MCP/Setup.swift`) |
| The agent port | editable | shown read-only when `SEARCH_MCP_PORT` sets it: "This run listens on N, set by SEARCH_MCP_PORT." | `Fork/SettingsFork.swift` |
| Copper's passwords and passkeys | the keychain | a 0600 file in the world when asked (`probe.keychain file`) | `ProbeKeychain` (`Fork/Credentials/ProbeKeychain.swift`) |
| A question before a destructive action | a sheet | held for `bench settings confirm` (headless) | `TestConfirm` |

A Settings change that copies, opens, writes outside the world folder or touches a system
setting needs a seam like these and a line in that test. More on worlds and dev builds:
[headless.md](headless.md).

## Performance

`Fork/SettingsPerf.swift` meters what Settings costs the main thread. Both meters are off until
the bench asks: body evaluations counted by name (`let _ = SettingsPerf.tick("line")` at the top
of a `body`), and main-thread busy time from two run-loop observers.

- **`./bench --world W settings perf run`**: opens Settings on General, sits, visits every page,
  types "password" a letter at a time, scrolls Passwords and sits again. Each step reports its
  own busy time, longest stretch and bodies drawn: the open, `typing.meanBusyMs` per keystroke,
  and `pageSwitchMeanBusyMs` / `pageSwitchLongestMs`.
- **`settings perf switch [N]`**: every page N times, each change pushed through an update, with
  a median per page.
- `settings perf churn`, `perf scroll`, `perf layers` and `perf [reset|stop]` for the rest.

There are no fixed thresholds. Compare the branch with `fork` back to back, in one world, on the
same display backing (a 2× backing costs about twice as much headless), and treat the three
numbers as gates: no worse to open, to type, or to switch pages. On the tree that shipped the
Settings pass (1.0.20261008.46): opening 106.4 ms busy (first frame 14.6 ms), a keystroke
45.6 ms, a page switch median 31.8 ms. A body count that grows with every keystroke or every
published tick means a view is observing more than it needs; the panel deliberately doesn't
observe `browser` (see the comment on `SettingsPanel.browser`).

## Checking a change

Before a Settings change ships, in a fresh world:

```sh
./build.sh
defaults write com.officecommun.search.test.set bench -bool true   # once per world, before launch
open -n -g --env SEARCH_PROBE=set --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT=4196 build/Copper.app
./bench --world set settings index check
./bench --world set settings ax sweep
./bench --world set settings confirm selftest
./bench --world set settings browse picture spaces /tmp/spaces-345.png 345 light
./bench --world set settings perf run
```

and the unit tests. With the Command Line Tools, `swift test` needs the testing macros plugin
named:

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

If the newest SDK can't find SwiftUI's macros, pin the SDK as the build recipe in
[headless.md](headless.md) does (`SDKROOT=…/MacOSX26.5.sdk`). The Settings suites are
`SettingsShellTests`, `SettingsAITests`, `DataSettingsTests` and `PasswordCSVTests`.

What a test run can't show, check by hand on the installed Copper: Tab with Keyboard navigation
on, VoiceOver reading a switch's name and value, a search landing gliding (headless jumps), and
the dialogs and real-account actions listed in the plan record.
