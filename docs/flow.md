# Move in (Flow)

Move in is Copper's one sheet for bringing your tabs, bookmarks, history,
passwords and sign-ins over from Chrome, Safari or Arc. It reads the other
browser's files on this Mac (or a file it exported) and never changes them.
Why it is built the way it is — the live demo where it brought nothing and
the sheet cycled — is in
[plans/2026-10-07-move-in-and-settings.md](plans/2026-10-07-move-in-and-settings.md).

## How it is built

Everything is in `Sources/Search/Fork/Flow/`. Readers produce the shapes in
`FlowModel.swift` and never touch Copper's state; only `Flow.swift` puts what
they read into Copper.

| File | What it holds |
|---|---|
| `Flow.swift` | `Flow.shared`: the sources (`FlowSource`), detection (`Flow.detect`), the scan, the move, the report, `present(from:via:)` and every `bench flow` verb |
| `FlowState.swift` | the rules, apart from AppKit and SwiftUI so each can be tested: `FlowMachine` (what is picked, when to re-check), `FlowScanTicket` (only the newest scan for the selected source lands), `FlowEvents` (every open, present, dismiss, refresh and scan), `FlowAdopt` (moving in again), `FlowSummary` (one row per category) |
| `FlowPresenter.swift` | the only owner of the sheet on screen (`FlowSheetWindow`, its size, ending it before quit) and `FlowKeys`, the ⌘ keys while it is up |
| `FlowUI.swift` | `FlowSheet`, the sheet's content: header, a middle that scrolls, a pinned footer |
| `FlowAccess.swift` | readable, locked or missing, from one real directory read; whether the app is installed (for "installed, never opened"); the System Settings deep links |
| `FlowFiles.swift` | the export pane: a dropped or picked bookmarks HTML, passwords CSV or Safari zip |
| `FlowSecrets.swift` | where passwords and passkeys go and where the browser's key comes from; `FlowKeychainSink` and, in a test run, `FlowProbeSink` |
| `FlowChromeTabs.swift`, `FlowChromium.swift`, `FlowBookmarks.swift`, `FlowCookies.swift`, `FlowPasskeys.swift`, `FlowExtensions.swift`, `FlowExtensionState.swift`, `FlowLocalStorage.swift` | the Chrome-family readers (Arc and other Chromium browsers share them) |
| `FlowArc.swift` | Arc's sidebar (`StorableSidebar.json`): spaces, pins, folders |
| `FlowSafari.swift`, `FlowSafariFormats.swift` | Safari as a source; its plist, `History.db`, tabs database and export zip |
| `FlowBookmarksHTML.swift` | the one bookmarks-HTML parser, for Chrome's export and Safari's |
| `FlowBench.swift` | small helpers for `bench flow` answers |

What a move leaves in the world's settings: `flow.spaces.<source>` (the
registry, the source's key for a space → the Copper space it became),
`flow.brought.<source>` (the addresses each of those spaces has brought), and
`flow.movedAt` (one dictionary: when each source last moved in). In the first
two, `<source>` is lower-case: `flow.spaces.chrome`, `flow.spaces.arc`,
`flow.spaces.safari`.

## Opening it

Every door goes through `Flow.present(from:via:)`: ⌘K "Flow: move in from
Chrome, Safari or Arc", Settings › General › Move in from another browser (**Move
in…**), View › Move in from Another Browser… (⌥⇧⌘I), and `bench flow open`.
From Settings, Settings closes first with nothing animating and the sheet
comes up on the next turn, so its text never morphs out of Settings' closing
animation.

- **One sheet.** `FlowPresenter` is the only thing that puts it on screen: an
  AppKit sheet on the window that asked (else the key window). With two
  windows there is still one sheet, and rebuilding a window's page area
  behind it doesn't dismiss it.
- **One size.** 560 points wide and up to 640 tall (less in a short window).
  The content never sizes the sheet: a header, a middle that scrolls, and a
  footer pinned to the bottom. A new phase redraws the middle in place.
- **Keys.** Escape closes it (so does ✕, read as "Close"). Return presses the
  primary button in every state: Bring it all over, Move in again, Done. ⌘W
  closes the sheet, never the tab behind it; other ⌘ shortcuts (⌘T, ⌘K, ⌘L,
  ⌘N, ⌘,) wait until it is closed (`FlowKeys`). ⌘Q, ⌘H, ⌘M and ⌘` still
  work, and ⌘Q quits with the sheet up.
- **Fresh each time.** Reopening shows the picker with every switch on, not
  the last summary — unless a move is still running, which it shows, or one
  finished after its sheet was closed, whose summary waits for the next open
  (with a line in the window when it lands). Asking for it in another window
  while it is up brings its window forward.
- **Nothing is read before it opens.** Listing another browser's folder is a
  request macOS records (and for Chrome's, refuses), so sources are looked
  for only when the sheet opens, off the main thread. The ⌘K history nudge
  looks only at Arc's folder, one level deep, at most once a minute.

## Picking a source

A source is found by its profile folders (`Default`, `Profile 1`, … with a
`Preferences` file), not by `Login Data`, so a browser with no saved passwords
still appears. Each card is one of:

| Card | Shows |
|---|---|
| Readable | the browser and its profile count (Safari: what Copper reads — its files, its export, or both); picking it reads its counts |
| Locked | "macOS needs your OK before Copper can read Chrome." with **Allow in System Settings…** and **Use an export instead…**; Safari's says the same with **Allow Full Disk Access…** |
| Installed, never opened | dimmed: "Open Chrome once, then come back." |
| Not installed | not listed (Safari comes with macOS, so it is always listed) |

When exactly one source can be read it is picked for you; otherwise you pick
(the footer says "Choose a browser above to see what comes over" until you do).
A selection is never switched under you, and only the newest read for the
selected source lands. The list is re-checked when Copper comes back to the
front — only while the sheet is up and a source is locked.

### When macOS keeps Chrome's folder private

On recent macOS another app's data under `~/Library/Application Support` is
protected ("App Data", `kTCCServiceSystemPolicyAppDataDetailed`). Chrome's
folder is; Arc's is not. That protection **never shows a prompt**: macOS
records Copper's first read as refused (tccd: "does not allow prompting;
recording denied"), which is also what lists Copper in System Settings.

- **Allow in System Settings…** opens Privacy & Security › Files & Folders
  (Full Disk Access if that page can't be opened). Turn on Copper's switch for
  Chrome and come back: the card unlocks by itself, with nothing to reopen.
  Full Disk Access lets Copper in too.
- **Use an export instead…** needs no permission. Drop a file on the sheet or
  choose it:
  - bookmarks: in Chrome, ⋮ › Bookmarks and lists › Bookmark manager, then
    ⋮ › Export bookmarks (an `.html` file);
  - passwords: in Chrome, ⋮ › Passwords and autofill › Password Manager ›
    Settings › Export passwords (a `.csv` file).

  A file brings only bookmarks or passwords — no open tabs, history or
  sign-ins — and the pane says so. Files are recognised by what is in them,
  not their names. Bookmarks go through the same merge as a direct read
  (`FlowBookmarksHTML.read(…, layout: .chromium)` then `FlowBookmarks.take`),
  so taking the same file twice, or the file after a direct read, replaces
  rather than doubles. Passwords go through Copper's CSV import into the
  keychain. Each file gets one sentence back: what arrived, or why nothing did.

Releases are signed with Copper's own certificate (since 1.0.20261007.42), so
macOS keeps a grant across updates: the Files & Folders switch, Full Disk
Access and a keychain "Always Allow" are given once. Builds signed ad hoc
before that release were tied to one build each, so they have to be given
once more after updating to it.

Giving it once more is not enough on its own for App Data: tccd keeps the
ad-hoc build's record (its `cdhash` requirement), never matches the signed
build against it ("Failed to match existing code requirement"), records each
read denied again, and the switch falls back off whenever it is turned on.
So **Allow in System Settings…**, while the folder is locked, first clears
Copper's own App Data record (`tccutil reset SystemPolicyAppDataDetailed
<bundle id>`; the locked record grants nothing) and lists the folder once, so
the record the switch changes carries the running signature.

### Safari

Safari's files (`~/Library/Safari`, and its container for open tabs) are
behind Full Disk Access, so Safari has two ways in, and either or both may be
there:

- **Its own files**, with Full Disk Access: open windows, tab groups and
  pinned tabs (`SafariTabs.db`), bookmarks and the Reading List
  (`Bookmarks.plist`) and history (`History.db`, every profile's). Finding
  out lists `~/Library/Safari` once and opens its two stores, only when the
  sheet opens and when Copper comes back to the front while Safari is locked;
  Full Disk Access answers that and never shows a prompt. The container is
  opened only after those opened, so without Full Disk Access it is never
  touched.
- **Its export**: in Safari, File › Export Browsing Data to File… saves a zip
  with bookmarks and the Reading List, history (one file per profile),
  passwords, payment cards and extensions. Drop it on the sheet (anywhere on
  the list, or on the export pane) or choose it there; the folder it unzips
  to, or one bookmarks `.html` or passwords `.csv` on its own, works too.
  Files are told apart by what is in them, never by their (localized) names.
  The export is kept for this session only.

The locked card is one sentence — "macOS needs your OK before Copper can read
Safari." — with **Allow Full Disk Access…** (Privacy & Security › Full Disk
Access; Copper looks again by itself when it is back in front) and **Use an
export instead…**. Back from System Settings and still locked, it says so:
"Still locked. If you just turned on Full Disk Access for Copper, quit and
reopen Copper." Once an export is in, Safari's card reads "The export from
Oct 7" (or "Its files and the export …") and is picked for you.

Passwords come only from the export: Safari's own are in the keychain, and
Copper never reads them. The export's CSV goes through Copper's one CSV
module (`PasswordCSV`), so macOS asks nothing.

## What moves

| Row | What comes over | Its hint |
|---|---|---|
| Tabs and windows (Arc: Tabs and spaces) | each window (Chrome) or space (Arc) with its open pages as sleeping tabs; pinned tabs and tab groups | "12 tabs in 2 windows" |
| Bookmarks | account and local bookmarks of every profile | "340 bookmarks" |
| History | every visible page with a visit, every profile | "4,812 places" (counted, not read) |
| Passwords | saved logins (needs the browser's keychain key) | "58 passwords" (counted without the key) |
| Passkeys | passkeys saved to the browser's own password manager (needs the key) | "2 passkeys" |
| Sign-ins | cookies, so you stay signed in (needs the key) | — |
| Site data | what sites keep in the page: settings, drafts, workspaces | — |
| Extensions | Chrome Web Store extensions Copper can install, on or off as they were | "8 extensions" |

Safari's rows are only what Safari has:

| Row | What comes over | Its hint |
|---|---|---|
| Tabs and tab groups | each window and named tab group as a space, pinned tabs as pins (its own files only; private windows never) | "7 tabs in 3 spaces · 2 pinned", or "not in Safari's export" with **Allow Full Disk Access…** |
| Bookmarks and Reading List | Favorites at the top level, then a Bookmarks Menu folder, the other items and a Reading List folder | "4 bookmarks · 3 in Reading List" |
| History | every web page with a visit, every profile, the files' and the export's merged | "553 places" |
| Passwords | the export's passwords CSV | "2 passwords", "none in this export", or "only in Safari's export" with **Add the export…** |

Under them one line names what can't come: "Stays in Safari: 2 payment cards
and 1 Safari extension."

Hints are counts only, "counting…" while the source is read, "none found"
when there are none. When Passwords, Passkeys or Sign-ins is on, one line
under the rows says "macOS will ask once to let Copper use Chrome's saved
passwords and sign-ins."

**Bookmarks.** Chrome keeps signed-in synced bookmarks in `AccountBookmarks`
and local-only ones in `Bookmarks`; Flow reads both for every profile, in
profile order, account first. The bookmark bar becomes Copper's top level,
followed by `Other` and `Mobile` folders for Chrome's other roots. Matching
folder names merge recursively and an identical URL and title at one level is
kept once — in linear time, so tens of thousands of bookmarks merge without
a pause. The merge is worked out off the main thread; only the swap of the
top level happens on it. Your own top-level bookmarks stay where they are and
imported ones follow them; a clashing folder name gets ` (Chrome)`. A repeat
import replaces the untouched top-level items of the previous one; anything
you edited, moved or saved yourself stays. If a present bookmark file can't
be read, the earlier imported roots are kept and what could be read is
merged in. The roots a source owns are recorded in
`flow-bookmarks-<source>.json` in Copper's data folder.

**History.** Every visible URL with a visit from every profile; Copper keeps
up to 20,000 places and merges a repeat import idempotently (the larger visit
count and the newest title and date win). It is taken in batches so the
window keeps drawing.

**Tabs.** Chrome's open windows come from its newest `Session_*` file.
`Tabs_*` is Chrome's recently-closed list and is never replayed as open tabs.
A window that held only new-tab pages makes no space: it becomes a line in
the summary. Imported tabs don't load until their space is shown, and count as
seen at the move, so Today's archive sweep doesn't close a tab Chrome or Arc
last showed weeks ago.

The new spaces are written to `session.json` as soon as they are made, before
the keychain, cookies and extensions that follow; a quit during those keeps
them. Extensions install one after another in the background with no dialog
per item. Every step logs one `Copper: Flow …` line (`log show --predicate
'process == "Copper" AND eventMessage CONTAINS "Flow"'`).

## The keychain

Passwords, passkeys and sign-ins are encrypted with a key the other
browser keeps in the macOS keychain ("Chrome Safe Storage"). macOS asks once
before handing it over; say **Allow**. The sheet says so under the switches
whenever one of the three is on, and the window keeps working while macOS
asks. The key is read once, off the main thread, and never written to disk;
the keychain writes happen off the main thread too. Then each of the three is read on its own: a broken cookie jar costs only
the sign-ins, and a refused key is said against each thing it would have
unlocked. Cookies are installed into WebKit and awaited, so the count is what
WebKit took, not what was read. They go into Copper's shared jar — where the
first profile's spaces (Chrome's `Default`, Arc's default profile) open their
pages — and each other profile's own go into that profile's jar too, for the
spaces that wear it (`Chrome · Work`), so neither opens signed out.

## Moving in again

A move is a one-time thing: once a browser is in, the sheet says "Moved in
from Chrome on …" and running it again is **Move in again**. A second move
adds only what is new:

- **Spaces fill.** Each source keeps a registry, `flow.spaces.<source>` (the
  name a space or window has in that browser → the Copper space it became),
  and a record of the addresses each one brought, `flow.brought.<source>`. A
  space an earlier move made is filled with the pages it doesn't have; one you
  deleted is made again; a space with nothing to open is never made. A page
  that was brought once — even if it redirected, or you closed it — isn't
  brought again. Arc, Chrome and Safari (`flow.spaces.safari`) use the same
  rule.
- **Names.** A space whose name you already use gets the source's name:
  "Work (Arc)", "Work (Chrome)", then "Work (Chrome) 2".
- **Everything else** is idempotent: bookmarks replace the last import's,
  history and passwords merge, passkeys already kept are skipped, cookies are
  set again. A Safari export with no bookmark file in it (passwords only)
  leaves the last Safari move's bookmarks alone.

## While it moves

The middle of the sheet becomes one row per switch that was on, made when
the move starts and changed in place: waiting, working (with what it is
doing: "asking macOS for Chrome's key…", "2,000 of 4,812 places…"), then a
check with what arrived or a dash with why nothing did — the same words the
summary uses. Nothing is added below, so nothing grows or pushes the footer.
There is no button while it moves; the sheet can be closed and the move
keeps going.

## The summary

When the move is done the sheet shows one line per switch that was on: a
check with what arrived, or a dash with why nothing did.

- "Tabs: 3 tabs in 1 space — 2 already here"
- "Tabs: 228 tabs (5 pinned) in 4 spaces — 3 empty spaces left out"
- "Tabs: Chrome's last window had only new-tab pages"
- "Tabs: Chrome had no open windows" (no session file at all — a fresh
  profile); "couldn't read Chrome's open tabs" only when one is there and
  can't be read
- "Bookmarks: Chrome has none"
- "Bookmarks: 7 bookmarks (3 from the Reading List)"
- "History: nothing new — 44 places already here"
- "Passwords: macOS didn't hand over Chrome's key"
- "Sign-ins: 2 sites (3 cookies)"
- "Extensions: none from the Chrome Web Store"

Under the lines, a Safari move says what stayed and why, a sentence each:
open tabs when only the export was read, passwords when there was no export
(or notes and one-time codes, which don't move), payment cards and Safari
extensions.

The title is "Moved in from Chrome", "Nothing new from Chrome" or "Nothing
came over from Chrome". The summary stays up until **Done**, which closes the
sheet and lands on the first space the move made or filled. **Undo the tabs**
takes back only the tabs and spaces this move added; spaces an earlier move
made keep what they had.

After a Chrome move that brought tabs or bookmarks, **Open the Chrome guide**
opens *Switching from Chrome*: a local canvas on where Chrome's windows, tabs
and bookmarks landed, the sidebar, and the keys to start with. It never opens
by itself. It stays on this Mac even with Copper Cloud signed in; a later press
reopens the same canvas, edits and new name included, without adding its
template again.

## What doesn't move

Apple Passwords (except what Safari's export carries), iCloud tabs, and a
password manager's own vault. From Safari: payment cards (Copper doesn't keep
card numbers), Safari extensions, password notes and one-time codes. Chrome
passkeys saved to iCloud Keychain rather than Chrome's password manager can be
read only by Apple's own stack. Arc's per-space profiles and passwords depend
on Arc's keychain key; without it the spaces still arrive, signed out.

## Test runs

Every `bench flow` verb works in an isolated `SEARCH_PROBE` world with bench
on; the ones marked *test run* do nothing anywhere else.

| Verb | What it does |
|---|---|
| `flow sources`, `flow probe` | the sources and what was found where |
| `flow root --source Chrome --path DIR` | *test run*: read a copy instead of the browser's folder |
| `flow root --source Safari --path DIR\|none` | *test run*: a copy of Safari's files (`Safari/` + `Container/`), read as if Copper had Full Disk Access |
| `flow limit --only Chrome,Safari,Arc` | *test run*: list only these sources |
| `flow scan\|move --source Safari --zip ZIP` | *test run*: take Safari's export first (as the pane does), then count or move |
| `flow file --source Safari --path ZIP`, `flow export --source Safari [--clear]` | Safari's export dropped on its pane / the pane, or let go of the export |
| `flow allow --source Safari` | the card's Allow Full Disk Access… (a test run names the page; the card then says what else it takes) |
| `flow access --source Chrome [locked\|clear]` | what macOS says about every file a move reads; *test run*: say it is locked (no folder touched), or clear that |
| `flow allow` | the locked card's Allow in System Settings… (a test run opens nothing and names the page) |
| `flow activate` | what coming back to Copper does |
| `flow open [--via settings\|command\|menu] [--window N] [--again]`, `flow close` | the sheet, through a door |
| `flow state`, `flow events [--clear] [--all]` | phase, selection, the sheet's frame and host; every open, present, dismiss, refresh and scan, `overlapping`, `scansPerOpen` |
| `flow key escape\|return\|tab\|cmd-KEY`, `flow shot --path OUT.png` | a real key on the sheet (`cmd-w`, `cmd-comma`: a ⌘ shortcut through the app's key handling); the sheet as drawn |
| `flow pick --source S` | a source card clicked: its counts are read in the background, answers at once |
| `flow scan`, `flow choose --only tabs,history`, `flow move --source S --only …`, `flow status` | read, set the switches, move (polled until done), the report |
| `flow export`, `flow back`, `flow file --path FILE` | the export pane and a dropped file (polled until read) |
| `flow passphrase --source Chrome --path PASS` | *test run*: a test passphrase for an encrypted fixture |
| `flow secrets [--clear]` | *test run*: what the in-memory stand-in holds (password digests only) |
| `flow guide`, `flow done`, `flow undo` | the done screen's buttons |
| `flow spaces`, `flow registry --source Arc`, `flow bookmarks` | what landed (each space with the profile jar it wears, `shared` or a profile folder) |
| `flow slow --seconds S` | *test run*: pause after each step, to watch the moving view |
| `flow file-status` | the export pane's last file: still reading, what it said, the bookmark count |
| `flow bookmark-move --id ID` | *test run*: move a top-level bookmark to the end, as a person would, to prove ownership |
| `flow localstorage --source S --path OUT.json [--root DIR]` | the localStorage reader alone, written as `arc-localstorage` JSON (reads only) |

Probe seams (all only in a test run): a test passphrase replaces the
keychain read, and what it unlocks — and Safari's or a file's passwords — goes
to the probe's stand-in (`FlowProbeSink`), never the keychain: the world's
file keychain (`ProbeKeychain`, `probe.keychain file`) when it has one, so
`bench passwords list` sees them and a second move knows them, else memory —
without a passphrase, a test run reads no Chrome secrets and says so; a
probe (`SEARCH_PROBE`) never looks at this Mac's own Safari (it is listed only when a
script names it, and is locked unless given a copy); `flow.installed` (a comma-separated list in the world's
defaults) stands in for "is the app installed"; `flow access … locked` stands
in for macOS's refusal.

Chrome, Arc and the other Chromium browsers have no such guard: a probe that
opens Move in without `flow limit` and `flow root` lists this Mac's own
folders, and asks macOS for Chrome's (as the dev app, so the installed
Copper's grant is untouched, but the request is real). A dev build opened without
`SEARCH_PROBE` (the world `dev`) is not a probe at all (`Flow.probe`) and
looks at Safari's real files too. The scripts below point
every source they move at a fixture with `flow root`, and the ones that open
the sheet list only their fixtures with `flow limit`; do the same by hand.

End-to-end scripts. Each makes a fresh headless world (launched through
LaunchServices, its own port, removed at the end), reads only generated
fixtures or the read-only copies you name, and never the keychain. Build
first (`./build.sh`; the scripts use `jq`, `perl` and `python3`), then run
from the repository root; each takes a path to the app (default
`build/Copper.app`), prints one `ok` line per check and exits non-zero when a
check fails:

- `docs/fixtures/flow-sheet-e2e.sh` — one sheet with two windows, one size,
  every door, Escape and Return, ⌘ shortcuts waiting behind it and ⌘W closing
  it (not a tab), a move closed mid-way showing its summary next time, ⌘Q,
  nothing read at launch.
- `docs/fixtures/flow-move-e2e.sh [--chrome DIR] [--arc DIR] [--shots DIR]` —
  Chrome locked → card → export files → let in → move → summary → Done →
  reopen → move again adds nothing → Undo; Arc twice from a copy, every space
  shown and swept.
- `docs/fixtures/flow-secrets-fixture.sh` — a synthetic encrypted profile:
  passwords, passkeys and cookies arrive in the stand-in with a test
  passphrase, a second move adds none, the first profile's space wears the
  shared jar and a second profile's space gets its sign-ins in its own, a
  broken cookie jar costs only the sign-ins; `--make DIR` writes the fixture
  only.
- `docs/fixtures/flow-sheet-shots.sh OUTDIR` — every state, light and dark, and
  the sheet's frame through a move.
- `docs/fixtures/flow-safari-e2e.sh [--data DIR] [--shots DIR]` — Safari
  locked with no copy, then its export (a synthetic zip from
  `flow-safari-fixture.py`): counts, move, twice; a passwords-only export
  leaves bookmarks alone; then a direct copy, twice; a read-only real-scale
  copy if given (`--data`, counts only); and Chrome, Safari and Arc in one
  world, one space each, no duplicates.
- `docs/fixtures/flow-bookmarks-e2e.sh`, `flow-canvas-e2e.sh`,
  `flow-extensions-e2e.sh` — bookmark merge and ownership, the Chrome guide
  through its button, extensions kept on or off (`flow-extensions-e2e.sh` runs
  `./build.sh` itself and takes no argument).
- `docs/fixtures/flow-extensions-parser.sh` — no app needed: compiles the
  extension reader with small stubs and checks the same copied fixture, for
  when a full build can't run.

The sheet's rules and the readers are also unit-tested (`swift test`, the
command is in [settings.md](settings.md#checking-a-change)): `FlowStateTests`,
`FlowMoveTests`, `FlowChromeTabsTests`, `FlowBookmarksMergeTests`,
`FlowBookmarksHTMLTests`, `FlowSafariTests` and `FlowSafariSourceTests` in
`Tests/SearchTests/`. Which of these catches which failure is listed in the
plan record's regression guards.

`./arc-import` remains for older installations and one-off recovery, but is
superseded by Move in.
