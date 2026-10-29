# The sidebar's three sections

Arc's sidebar is three blocks, and Copper's are the same three.

**Favourites** — the grid of squares at the top. Upstream's pins; nothing
here changed them.

**Saved** — the tabs you keep, above the hairline and the "New Tab" row. It
is the long block and the only one that scrolls without limit. Folders (tab
groups) live here: a Today row that joins a folder comes up with it.

**Today** — everything else, newest at the top, under the "New Tab" row. It
takes only as much of the column as it needs, up to a few hundred points.

## Which block a tab is in

An explicit flag, not a guess. `Session.Entry.saved` travels in the session
file, and `Sections.saved` holds it while the app is up. A file written by
upstream Search has no flag at all, so everything in it restores as saved —
an old session never lands in a block that archives itself.

A tab crosses the seam three ways:

- drag it — a Today row — onto the New
  Tab row or anything above it, and let go: it is saved where it was let go
  (below); drag a Saved row past the middle of the New Tab row and let
  go: it is unsaved;
- **Save** / **Unsave** on the row's context menu;
- `./bench sections save ID` / `./bench sections unsave ID`.

**Save** parks the row at the bottom of Saved, right above the seam, and the
column scrolls there so it does not look as if the tab vanished. Unsaving
puts it at the top of Today, and takes it out of its folder, since folders
are a Saved thing.

## Dragging into Saved

A row in the hand is over Saved as soon as the pointer is over the New Tab
row or higher — from the first Today row that is a drag of about 25 points.
From then on (`Fork/SavedDrop.swift`):

- a row's room opens where it would land — between two rows; inside a
  folder, the room stepped in like the folder's rows; onto a folder's own
  line, the room opens as the folder's first row and the folder is ringed
  in the space's colour (a shut one opens when the row lands in it);
- the row rides above the column on a card, stepped in as far as the room,
  and its own place in Today is left empty;
- let go, it is saved at the room, in that folder. Below Saved's last row —
  the hairline, the New Tab row — is the end of Saved at the top level.

Back over Today the room shuts at once and the row reorders inside Today as
it always has. A Saved row moved inside Saved gets the same room and lands
the same way — into a folder, out of one, or between two — and over its own
place none opens. (It used to reorder by counting rows, so a shut folder's
hidden rows counted and a row dragged out of one folder fell into the
next.) Between Saved's last row and the middle of the New Tab row is the end
of Saved at the top level, which is how a row leaves a folder that ends the
block. Past the middle of New Tab a Saved row is over Today; the room opens
at the top of Today, where an unsaved row goes.

Any row carried up above the column, over the favourites, opens a place at
the end of the grid (shown even when there are no pins yet); let go there
and it is pinned.

An empty Saved block has no rows to open a room between: once a Today row
is carried onto the New Tab row, a place opens above
the hairline instead — *Drop here to save*, ringed in the space's colour —
and letting go there saves it. Back over Today it shuts again.

Where a drop lands is `SavedDrop.target` — a pure function of the pointer
and the frames the column reports in its own coordinate space — and
`SavedDrop.index` says where in the row that is; both are unit-tested
(`Tests/SearchTests/SavedTabsTests.swift`). Up to October 2026 a row crossed
only when let go a row and a half past the edge of its own block (past the
middle of the New Tab row) and always landed at the bottom of Saved.

## Closing a Saved tab

As in Arc, closing a Saved tab does not unsave it. ⌘W, File › Close Tab,
the wheel button on the row, Close Tab in ⌘K, Close Other Tabs, a split
pane's cross, an agent's or the CLI's close, an extension's
`tabs.remove`, and closing a window's last tab all reach `Browser.close`,
which asks `Sections.putsDown` first. A Saved row on a page is then **put
down** — its page let go as ⌘W lets a favourite's go (`Tab.rest`), its
title, mark and place kept, nothing dimmed: it looks exactly like a row
brought back asleep from the last session — and you land where a close
would have landed you: the row to the right, else to the left, passing over
rows already put down. With nothing else open, a blank tab, as a close of
the last tab leaves one; closing that blank closes the window. Clicking the
row loads it again.

Taking a row out of Saved is on purpose: the cross on the row (or on its
pill in the top bar), **Close Tab** on its context menu, **Close Tabs in
Group** on a folder, and **Unsave**. The first three go through
`Sections.remove`: the tab closes for good and its Reopen Closed Tab entry
remembers it was Saved, and in which folder — ⌘⇧T puts it back at its place
in Saved, in that folder if it is still there. Today rows close with the
cross and with ⌘W as they always have. Favourites are unchanged.

A kept tab deleted on another Mac, and a canvas deleted or left, close for
good too (`Sections.closeForGood`), with no way back into Saved.

Copper Cloud's *Spaces and kept tabs* document lists a Saved row whether
its page is loaded or not (`CloudApply.keptURL`), so putting one down
changes nothing on your other Macs; only taking it out deletes it there.
The session file writes a put-down row like any asleep one — `saved: true`.

## The archive

Each tab remembers when it was last in front (`Session.Entry.seen`, Unix
seconds). At launch, every half hour, and whenever you switch to a space,
Today rows nobody has looked at inside the window are closed — through
`Browser.close`, the same path the cross on the row takes, so every one of
them waits in **Reopen Closed Tab**. Saved rows and favourites are never
touched, and neither is the row you are looking at.

The window is **Settings › Tabs › Archive Today after**: 12h, 24h (the
default), 48h, or Never.

## The bench

    ./bench sections                     counts per space, Today with each row's age, Saved in order
    ./bench sections save ID
    ./bench sections unsave ID
    ./bench sections close ID            ⌘W on the row, through Browser.close
    ./bench sections remove ID           the row's cross
    ./bench sections reopen              Reopen Closed Tab
    ./bench sections check               close against remove on a Saved row, end to end (test worlds)
    ./bench sections seed [empty]        real rows, asleep: four Saved (two in a folder), three Today
    ./bench sections drag ID DY [STEPS] [hold]   real mouse events: pick the row up, move it DY points
    ./bench sections release | target    let go of a held drag; where it would land
    ./bench sections drop ID Y [hold]    a Today row let go at Y
    ./bench sections hover ID|off        the row under the bench's pointer, its cross showing
    ./bench sections click ID [cross]    a real click on the row, or on its cross
    ./bench sections picture PATH [EXTRA]  the window to a PNG, nothing brought forward
    ./bench sections archive             the sweep the clock would have run
    ./bench sections archive 2           …against a two-hour age instead, for tests
    ./bench sections window 12h|24h|48h|never

The drag, click and hover verbs hand their events straight to the view
under the row (`Fork/SideHand.swift`): a probe never has the key window,
and a press sent through the window would only try to make it key. In a
probe whose screen is locked, no event reaches SwiftUI's gestures at all.

## Importing from Arc

`./arc-import` marks Arc's per-space **pinned** tabs saved and its **open**
tabs Today, newest first, each carrying `timeLastActiveAt` as its `seen`
(Arc counts seconds from 2001; the importer adds 978307200). Arc's
favourites are still the pin grid, and Arc's folders are still tab groups.

