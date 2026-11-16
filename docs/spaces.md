# Spaces

A space is a row of tabs of its own — its favourites, its saved rows, its
Today — with a name, a colour the whole column is washed in, an icon, and
optionally a profile (a cookie jar of its own). One space is on screen at a
time; the others are parked and come back exactly as they were.

## Where the space shows

**The header.** Under the traffic lights, above the favourites: the space's
mark and its name in full. Hover it for the tab count; click it (or the
chevron) for the space menu. This is the label the column used to lack.

**Around the page.** In the sidebar layout the space's ground runs under the
whole window, and the page sits on it as a card: a 7pt margin on the top,
right and bottom, 11pt round corners, a hairline and a soft shadow — the same
card a split view's two panes are, and the agent's pane beside it. A space's
picture keeps the column's width and fades into its colour past it. The top
tab layout keeps its page edge to edge.

**The strip at the foot.** Every space is a 28pt chip — its emoji or its
symbol at 20pt, or its initial (11pt semibold) on a 20pt tile of its own
colour, so no two spaces look the same. The current one sits on the column's paper-white pill,
the same thing the live row wears. Hovering a chip names it at once, above
the strip, and its tooltip gives its key (`Work · ⌃2`). When the chips outgrow the
column the row scrolls sideways under a soft edge, with the current chip kept
in view; nothing shrinks to a dot and no name is ever cut to a letter. Drag a
chip to reorder the spaces. The `+` at the end makes a space *and opens its
editor*, so it gets a name, an icon and a colour straight away.

**Switching.** The rows slide sideways by the column's width, Arc's pager:
the old space's out, the new one's in, while the ground under them changes
colour in place. With Reduce Motion on nothing travels — the old rows fade
out, then the new ones fade in, never the two lists over each other. The
new space's page takes the card in the same frame as its rows: a page
already drawn is swapped in once WebKit has a frame of it (never faded over
the old one); a page that is waking shows its own last picture, or its
ground, until it draws. After a launch, the landing page of the space you
were in last is loaded in the background; another space's starts loading
when you show you are going there — the pointer resting on its chip, a
swipe setting off towards it, ⌃ held a moment (the spaces either side). A
page loaded ahead that you don't go to within a minute goes back to sleep
(`spaces.warm.cool`, seconds), so a guess costs no memory for long.

Where a switch's main-thread time goes: `bench pace` after a switch lists
its steps (`swap`, `swap.projection`, `swap.selected`, `swap.done`, then
`page.attach`, `slide.go` and `swap.committed` — the next pass after the
switch's own) beside every pass of 1 ms or more; `perf/a2steps.py` sums
them per arm from a `perf/a2.py` run.

## The space menu

From the header, a chip's right-click, or ⌘K:

- **Edit Space…** — the popover below.
- **New Tab in Space** — switches there if needed.
- **Move Current Tab Here** — on any space but the current one.
- **Move Left / Move Right** — reorder without dragging.
- **Colour ›** — the named palette, each with its swatch.
- **Profile ›** — Shared, the names in use, New Profile….
- **Delete Space…** — see below. Only when there is more than one space.

## Edit Space

One popover: the name (autofocused; ⏎ closes), a row of symbols and an
emoji field for the icon, the colour swatches, the profile picker, and
**Delete Space…** at the bottom. Every change lands as it is made — the
header re-titles and the column re-tints while the popover is up.

## Colours

Ten names, not degrees: **Graphite** (the plain grey), **Copper, Orange,
Yellow, Green, Teal, Blue, Indigo, Pink, Red**. A new space takes the first
colour no other space is wearing — never grey by default; grey is a choice.
A space restored from an older session or imported from Arc keeps whatever
hue it had; the picker shows it as the nearest name. `SpaceTint`
(`Fork/SpaceTint.swift`) turns the hue into everything the column draws.

## Deleting

Delete asks first — *"Delete 'Work'? Its 12 tabs will close."* — with
**Close Tabs & Delete**, **Move Tabs to 'Home' & Delete** (the neighbour to
the left, or to the right for the first space) and **Cancel**. A space with
no tabs asks with a plain **Delete**. The last space cannot be deleted.

## Shortcuts

| | |
|---|---|
| ⌃N | New Space |
| ⌃⌥← / ⌃⌥→ | Previous / next space |
| ⌃1 … ⌃9 | Switch to the nth space |
| two-finger swipe over the column | Previous / next space |
| ⌘K | New Space, Edit Space, Delete Space…, Switch to *name* |

## The model

`Space { id, name, hue: Double?, profile: String?, icon: String? }` — all of
it in `session.json` under `spaces`. `icon` is an emoji or an SF symbol name
behind `sf:`; it is optional, so a session written by an older build reads,
and an older build reading a newer file ignores it. Nothing else about the
file changed. `Fork/Spaces.swift` is the model, `Fork/SpacesUI.swift` the
views (header, strip, editor, menu, delete sheet).

## The bench

```
./bench spaces                              list: index, name, icon, tabs, profile, colour
./bench spaces new NAME                     a space in an unused colour, made current
./bench spaces select N|NAME | next | prev
./bench spaces icon N|NAME 📚|sf:flask|none
./bench spaces colour N|NAME Teal|…|Graphite
./bench spaces reorder N|NAME M             move a space to index M
./bench spaces move N|NAME                  the active tab, into that space
./bench spaces warm N|NAME | sides          load a space's landing page ahead, as hovering its chip (sides: as ⌃ held)
./bench spaces remove N|NAME [--keep]       --keep moves its tabs to the neighbour
./bench spaces edit [N|NAME]                the editor popover, on the header
./bench spaces delete N|NAME                the Delete sheet (prints its text)
./bench spaces answer close|move|cancel     press one of the sheet's buttons
./bench ui width 176                        the column's width, for a look
```
