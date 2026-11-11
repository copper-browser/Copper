# Gauntlet Loop — Copper vs Arc

Copper (`~/Developer/Copper`, branch `fork`) is a 3 MB WebKit browser for
the Mac, being pushed toward a full Arc replacement.
Tier 1 of `FORK-PLAN.md` has shipped as code — Spaces, Profiles, ⌘K command
bar, Split view — but it looks like a prototype next to Arc. This loop closes
that gap, one piece at a time: a builder builds, a fresh critic puts a
screenshot of Copper next to a screenshot of Arc and asks **which one was
made by the better product team?** Arc wins → name the one biggest gap, send
it back. Copper holds up → pass.

## The bar (what the critic compares against)

Real Arc screenshots in `.gauntlet/refs/`:

- `arc-sidebar-exowatt.png` — Collin's own Exowatt space in Arc: tinted
  sidebar, 6-favicon favourites grid, pinned tabs with favicons, folders
  (Misc, Benefits) with a chevron, "New Tab" row, today's tabs below it,
  space switcher dots at the bottom.
- `arc-command-bar-google-search.png` — the ⌘T command bar floating over a
  split view; note the row layout (icon · text · right-side action hint
  like "Instant Open"), the sidebar with a folder ("pantograph") and
  favicons, and two split panes each with its own small toolbar and ×.
- `arc-command-bar-raindrop.png` — same bar offering an extension action.
- `arc-split-view.png` — a two-pane split: rounded panes, gutter, per-pane
  toolbar (← → ↻ · url · ✕), the active pane outlined.
- `arc-spaces.png` — Arc's spaces UI.
- `arc-little-arc.png` — Little Arc (out of scope here, for flavour).

"Before" screenshots of Copper are `.gauntlet/shots/before-*.png`.

## What Arc feels like (so you do not need to guess)

Quiet, dense, warm. 13px sidebar text, ~28pt rows, 16pt favicons, generous
left padding, the whole sidebar tinted with the space's colour at low
saturation (light theme: a pastel wash; dark: a deep tint), active tab as a
soft pill in a slightly stronger tint of the same hue, hover barely there.
Nothing has a hard border; separation is by spacing and a hairline at most.
The command bar is a single floating card ~640pt wide, centred a third of
the way down, big input (~18pt), rows ~40pt with an icon on the left and a
muted hint on the right, no outline on the card itself, just shadow. Split
panes are rounded cards floating in the page area with an 8pt gutter, each
with its own hairline toolbar.

## Non-negotiables (read before editing)

- **Fork layout.** New code goes in `Sources/Search/Fork/`. Upstream files
  (everything else under `Sources/Search/`) get the smallest hook that will
  do the job, and every upstream file you touch gets a row in `PATCHES.md`
  in the same commit. `Side.swift` is the exception for the sidebar piece:
  the sidebar *is* upstream's, so you may reshape it, but keep the diff as
  small as the result allows and log it.
- **No dependencies.** SwiftPM stays dependency-free. SwiftUI + AppKit +
  WebKit only.
- **Reuse what is there.** `Favicons.shared.cached(host)` and `tab.icon`
  exist; `Palette`, `Metrics`, `Motion` hold the app's colours, sizes and
  animation curves; `Space.hue` is already on the model; `Spaces.shared`,
  `Split.shared`, `CommandBar` are the Tier 1 singletons. Read them before
  adding a sibling.
- **Light and dark both work.** Screenshots are judged in whatever the Mac
  is in (light today). Do not break the other.
- **`./build.sh debug app` must pass** before a round ends. There are no
  unit tests in this repo; the bench is the test harness.
- **Session file stays additive.** New fields on `Session.Entry` /
  `Session.Shape` are optional, so upstream-shaped files still restore.
- **Do not touch** `.github/`, `build.sh`, `Package.swift`, `Updater.swift`,
  `FORK-PLAN.md`, `COLLIN.md`, the `main` branch, or anything under
  `~/Library/Application Support/Copper/` (that is Collin's live profile —
  probe worlds live in `Copper (<world>)`).

## Running and screenshotting (how the critic sees your work)

Each piece has its own git worktree and its own probe world, so several
builders can run at once:

    .gauntlet/run.sh WORLD [CHECKOUT]      # build, seed with Arc, launch, land on Exowatt
    .gauntlet/shot.sh WORLD OUT.png [CHECKOUT]   # whole window → OUT.png and OUT.s.png (half size, open this one)
    ./bench --world WORLD spaces|tabs|select|summon "text"|bar "text"|split [ID|off]|ui KEY on|off|resize W H|probe

`run.sh` rebuilds, wipes and re-imports the world from Arc (`./arc-import
--world WORLD`, 6 spaces, ~250 tabs, the real thing), launches the binary
directly and waits for the bench. `summon "goo"` opens the ⌘K bar with that
text and leaves it open for a shot (`bar ""` closes it). `split ID` puts tab
ID beside the active one. `spaces select N` switches space. Sidebar tabs
start asleep; `select ID` wakes one.

Window shots come from inside the app (`bench window`), so they work with
other windows in front. Put screenshots in `.gauntlet/shots/<piece>-r<round>-<what>.png`.

**Quit what you launched.** `.gauntlet/stop.sh WORLD` quits the Copper that
`run.sh` started for that world. Every builder, critic and smoother runs it as
the last thing in their round — the critic relaunches with `run.sh` anyway, so
nothing is gained by leaving one up, and a dozen idle browsers slow the Mac
for everyone. `stop.sh all` sweeps every gauntlet instance. Never quit the
user's own Copper (the one without `SEARCH_PROBE`, on the live profile).

Copper's own hotkeys: ⌘K command bar, ⌃1–9 spaces, ⌃N new space, ⌘⇧D split.
`osascript` cannot send keystrokes on this Mac; drive everything through the
bench.

## Progress page

`.gauntlet/progress.html` is a plain static page (serve it with
`python3 -m http.server 8792 -d .gauntlet`). After each critic round,
**append** one `<section>`: piece, round, PASS/FAIL, biggest gap, our shot
beside the reference (paths relative to `.gauntlet/`). Never rewrite earlier
sections.

## Git

You work in your own worktree on your own branch (`gauntlet/<piece>`).
Commit your own files only (`git add <paths>`, never `git add -A`), one
logical change per commit, imperative subject. Never rebase, reset, stash
or touch another branch. The smoothing agent merges the branches into
`fork` at the end.

## Late changes on `fork` (read this — it overrides piece scopes above and in your prompt)

Felipe landed two features on `fork` after the loop started; every builder must
merge `fork` into their gauntlet branch **before** their next round (`git merge fork`,
build must pass):

- **Tab groups** (`Fork/Groups.swift`, `GroupsUI.swift`, `Grouper.swift`; hooks in
  `Side.swift` `loose` → `GroupedRows`, `Session.Entry.group`). A group is a name, a
  hue, `collapsed`, over a contiguous run of tabs in the row; persisted in
  `groups.json`. `./bench groups [new|assign|remove|dissolve] …` and `docs/groups.md`.
  `arc-import` now emits Arc folders **as groups**; a nested folder's name carries its
  parents joined with ` › ` (e.g. `Misc › BuildrFi › Useful Internal Pages`).
- **MCP server** (`Fork/MCP/`) — not a gauntlet surface; leave it alone.
- **Space swipe** (`Fork/Swipes.swift`): two fingers sideways over the sidebar steps
  spaces. `./bench swipe left|right|down`.

**Sections piece (new).** Arc's sidebar is three sections and Copper's must be
the same three, for real: **Favourites** (the pin grid), **Saved** (Arc's pinned
tabs — an explicit persisted `Entry.saved` flag, not "whatever was restored"),
and **Today** (everything else, under the hairline + New Tab row, auto-archived
after 24h — 12h/24h/48h/never in Settings — through the normal close path so it
lands in reopen-closed-tabs). Drag across the seam / context menu / `bench
sections save|unsave ID` move a tab between the two; `sections archive` runs the
sweep now. arc-import marks Arc pinned as saved and gives Today tabs their real
`timeLastActiveAt`. Groups (folders) live in Saved.

**Folders piece — new scope.** Do **not** build a `Folder` model or touch `Session`.
Copper's folders *are* Felipe's groups; make them render like Arc folders:
- Nesting from the ` › ` names: a group whose name starts with another group's name
  + ` › ` is its child — draw only the last segment, indented 16pt per level, under
  its parent's header; collapsing a parent hides its children's headers too.
- Header row: chevron that rotates, a folder glyph (tinted with the group's hue or
  the space hue when nil), name in medium weight, muted count on the right only when
  collapsed. Children's tab rows indent 16pt (plus 16 per nesting level).
- Context menus already exist on Felipe's header (rename, recolour, ungroup, close
  all) and tab (Group ›) — keep them; add **New Folder Inside** on a header, which
  creates a group named `<parent> › <name>`.
- Bench: add `groups toggle NAME` (collapse/expand) so the critic can open one.
- Your worktree branches from `gauntlet/sections` (which contains the sidebar piece
  and `fork`).
  Style must match the sidebar piece; do not restyle the sidebar itself.

**Sidebar piece**: after merging `fork`, `Side.swift` gains `GroupedRows`; keep it
rendering and make its header row match your row style (same inset, 13px, favicon
column alignment). The critic will see Casual with 14 folders.

**Smoother**: `fork` has moved (Felipe's commits + swipe + arc-import). Merge the
gauntlet branches into the current `fork`; the `Side.swift` seam between the
sidebar piece and `GroupedRows` is the expected conflict. Also check `bench swipe left`
still steps spaces after the merge.
