# Canvas — a whiteboard in a tab

*An infinite board of stickies, text, frames, arrows, images and links that lives in an ordinary
Copper tab at `copper://canvas/<id>`. One **Personal** canvas always exists, works with no
network and no account, and is never shared — it stays on this Mac until you choose **Personal
canvas** in Settings › Cloud › Choose what syncs; with Copper Cloud signed in you can make shared
canvases, invite people, and see each other — and each other's agents — live. The ⌘E agent, MCP
agents and the `copper` CLI all read and write the same boards. Implementation:
`Sources/Search/Fork/Canvas/` (the page itself is built from `Canvas/`).*

## Using it

Canvas is Copper's one board. (It used to have two: Easels, a local-only board with a format of
its own, was folded into Canvas on 2026-10-01 — see [What happened to easels](#what-happened-to-easels).)

### Opening one

- **⌘K › New Canvas** (or ⌘T, typing "canvas"), or **File › New Canvas** (⌃⇧E, Arc's): a canvas
  in a new tab in front. A blank tab in front takes it instead, the way ⌘T reuses one. A canvas
  made this way is **local** — on this Mac, called *Untitled canvas* — whether or not you are
  signed in; sharing stays an upgrade, from the door's **New canvas** (signed in, it makes a shared
  one; ⌘K says **New Shared Canvas…** for it) and the invite flow.
- **From the sidebar**, where Arc keeps its new things: right-click the **New Tab** row (New Tab /
  New Canvas), right-click the **plus** at the foot (New Space / New Canvas; a click on it still
  makes a space), or **New Canvas in Space** on a space's menu (its header, its chip, ⌘K's space
  rows).
- **Sidebar › Canvas door** (at the foot, beside Bookmarks and Extensions): Personal,
  *Invitations* (invites waiting for your answer, with Decline / **Join**), *My canvases*, *Shared
  with me* and **New canvas**. While an invite waits the door wears a small dot in the space's ink
  (green when someone is live on a canvas) and its help says *1 invitation*. Click a row to open it. Right-click a row: Open, Open in Background, Copy Link,
  Rename…, Share…, Members…, Leave… / Delete….
- **⌘K / ⌘T**, typing a canvas's name: an **Open Canvas · <name>** row for each match, three at
  most. `canvas` alone (or `canvases`, or `canv`) lists them all, newest first; `canvas plan`
  narrows to names with "plan" in them. An open canvas also shows up in tab search like any tab,
  wearing the Canvas mark. **View › Canvas ⌘⇧O** opens Personal.
- Its address, `copper://canvas/<id>` (or just `copper://canvas` for Personal), typed or pasted
  into the field or the ⌘T card. An easel's old address, `copper-easel://easel/<id>`, opens the
  canvas that easel became.

However it is opened, a canvas's tab — the first time it loads — joins the current space's
**Saved** block at the bottom and is selected, the way Arc pins a board. Today's archive never
takes it, and the sweep passes over a canvas even when somebody drags it down into Today. A canvas
whose tab is already in the sidebar stays where it is (opening it goes to it). Session restore puts
each canvas tab back in its space and its block.

A canvas has **one tab**. Opening one that is already open — in this space, another space, or
another window — goes to that tab (the other window comes forward, the other space is switched
to). Only the bench's own tabs are exempt. This is `CanvasTabs.show`, and `CanvasTabs.already`
(`Browser.open`) and `CanvasTabs.reroute` (`Tab.go`) send every other way of opening one there.

### Its tab

An ordinary tab in every other way. The sidebar row (and a favourite's square, and ⌘K's row) wears
the **Canvas mark** (`CanvasPage.icon`) where a site wears its icon; the title is the canvas's
name — a sleeping or restored row says the registry's name, so a rename made while it slept shows
at once. The address pill says **Canvas · <name>**. It sleeps after half an hour and wakes from
disk, comes back after a relaunch, sits in split view, and moves between spaces. Links clicked on
the board open in a tab of their own; an address typed into a canvas tab's field opens beside it —
a canvas tab only ever shows its board.

### Its row

Right-click a canvas's row (or its square, if it is a favourite, or its pill in the top bar): the
canvas's own items come first, then Copper's tab items as for any tab. Personal has neither.

- **Rename Canvas…** opens a name field on the row, as a folder's Rename… does (a sheet where there
  is no row: a favourite's square, the top bar). Return keeps it, Escape or a click away leaves
  it. It is `Canvases.rename`, the door's Rename: a shared canvas is renamed on the cloud (and so
  needs it signed in — the item is greyed out without), every tab holding the canvas retitles, and
  an open board is told the new name (`copperCanvas.rename` when the page has it; otherwise the
  page is checkpointed and reloaded under the new name).
- **Delete Canvas…** asks first, in a sheet that says what happens: a local canvas — *Permanently
  deletes this canvas and everything on it from this Mac* —, a shared one you own — *…for every
  member* —, or, for a shared canvas somebody else owns, **Leave Canvas…** — *It stays for everyone
  else. Someone will have to invite you again.* Cancel is the default; Return confirms nothing. It
  is `Canvases.delete` / `Canvases.leave`, the door's: every tab showing the canvas closes — this
  row, a favourite, a row in another space or window — and its history on this Mac goes.

### What a canvas tab is spared

Every tab is built for the open web; a canvas is Copper's own page, so its tab is built lean
(`CanvasLean.swift`; `defaults write <domain> canvas.lean -bool NO` builds it like any tab, for
the bench's before-and-after). Only what the bridge does not need goes:

| every tab gets | on a canvas tab |
|---|---|
| back/forward swipe in `PageView.scrollWheel` (the sideways tracker, the page asked, the disc, `onTouch` per event) | **off**: the event goes to WebKit and nothing else; `onTouch` once per gesture |
| `Swipe.watch` / `Swipe.calm` scripts in every frame | off |
| `ScrollRelay`, `VeilRelay` (hide something), `ImageRelay` (Copper's image menu), `StoreRelay` (Web Store mender), the passkey shim | **off**, handlers too |
| `FormRelay`'s sign-in watcher (a `MutationObserver` over the document, capture listeners) | off; a 20-line script reports focus changes only, so Tab still goes to a sticky or a title |
| the ad blocker's rule list | off |
| WebKit's pinch magnification | off (the board zooms itself) |
| the `canvas` message handler, `callAsyncJavaScript`, the first-frame fade, the sleep picture, sleep after half an hour, the title/address/progress observers, the audio watch | **kept** |

`bench canvas lean` reads the page back: the bridge is there, the page's API is there, the host is
ready, and the web-page scripts are not. A canvas tab has no Chrome extensions (its configuration
is CanvasHost's, made for it, never an extension's).

- Signed out, everything cloud-shaped is hidden and the card says, in one line, that sharing lives
  at **Settings › Cloud**. New canvases are then local to this Mac. Shared canvases already kept
  here stay listed under **Signed out** with a line saying what that means: they open offline and
  keep your changes until you sign in again. With *another* account signed in they are only
  counted ("2 shared canvases are kept on this Mac for another account"), never named or opened.
- Row subtitles say what is true now: Personal is *Private · on this Mac* while its sync is off,
  *Private · connecting…* (its tab is up, the room hasn't answered) or *Private · sync on* (no tab open) while it is on, and *Private · synced* only once its
  room has answered with the server's side of the document; a shared board with no room reads
  *Offline · changes saved on this Mac*. The tab in front has a tinted row and a ✓; one open behind
  has a window mark ("Open in a tab"); the green dot's help says "1 collaborator live".
- Rename, Invite, Members and Delete open with a short title ("Rename canvas", "Invite to
  canvas", "Delete canvas") over the canvas's whole name, wrapped. Delete is a red **Delete
  canvas** that says what it does — *Permanently deletes this canvas and everything on it, for
  every member. This can't be undone.* — with Cancel first: Escape cancels and Return confirms
  nothing. An invitation row shows the whole name and who sent it (*From Ann · reminded you* once
  its sender has reminded you) above Decline / **Join**, says *Joining…* in the row while the
  answer is on its way, and stays — with the reason, in the row — until the server has said yes.
  **Join** accepts and opens the canvas in front.

## Checklists (RSVP)

A checklist card (the toolbar's list tool or `R`, or an agent's `{type:'checklist'}`) is a title,
one to four columns — *Yes* / *No* by default — and up to sixty rows: people for an RSVP, tasks for
a to-do list (one column draws plain task boxes; a ticked row keeps its label as it was, never
struck through, since a ticked name on an RSVP is a yes, not crossed out). Each row has at most one
pick. **One click** on a box picks it, a second click clears it — anyone who can edit, selected
or not, without opening the card; the title, the labels and the edges still drag it, and a
read-only board shows the picks without taking clicks. Each column header carries its count; a
picked box's tooltip says who picked it and when (*Ann · 4 min ago*). The boxes are buttons
(`role="checkbox"`): Tab reaches them, Space or Return toggles, the arrows move between them.
Double-click the title, a label or a column to rename it in place: Return in the title goes on to
the first row, Return in a row adds the next one, Backspace in an empty row removes it, and a
row left empty is dropped. While the card is hovered or selected, *Add row* and *Column* sit just
under it; a selected card shows × on a row to remove it. The height follows the rows (only the
side edges resize).

**Row comments.** Any row can carry a comment — why a pick, a caveat, a link — as long as it needs
to be. A row without one shows a comment button at the end of its label only on hover or keyboard
focus; a row with one shows a single muted line of it under the row, cut with an ellipsis, so a
long comment never takes over the card. A click on that line or the button opens it under the row:
a field that grows to eight lines and then scrolls in itself, with who last wrote it and when. The
same button, Escape or a click elsewhere closes it. Open or closed is each viewer's own (never
stored or shared). While one is open the card keeps the height it had and its rows scroll inside
it, so the stored size never changes and nothing spills past the card; it settles to its rows when
the comment closes. Everyone sees the words as they are typed.

**Assignees.** Any row can be assigned to one or more people (up to twelve). Their faces —
initials on each person's Copper colour, overlapping past one, `+N` past three, yours ringed in
the accent — sit at the end of the row; hovering one says who and who assigned them (*Collin
Rijock · assigned by Ann, 4 min ago*). A row with nobody on it shows a person button beside the
comment button, on hover or keyboard focus only. That button, a click on the faces, or `@` typed
while the row has focus (a box, its buttons) opens the people picker under the row: a field that
filters as you type (name start, word start, email), the arrow keys to move, Return or a click to
put the person on the row — or take them off, since it ticks who is on it already — and the field
clears for the next; Escape or a click elsewhere closes it. It lists the canvas's people — the same
list chat's `@` picker shows, you first — then names already used on this board's checklists, then
whatever name you typed (*Assign “Design team”*), so a canvas on this Mac works with names alone.
In a row's comment, `@` at the start of a word opens the same list under the comment: picking
someone writes *@Name* there and puts them on the row. On a shared canvas, someone newly put on a
row is **told the way a chat @mention tells them** (copper-cloud 0.6.0+, see Chat): the pill reads
*Ann assigned you in “Sprint”* with the row (and the card's title) as its line, the Canvas door
gets its dot and the canvas its `@`, and a Mac notification comes when Copper isn't in front.
**Open** shows the canvas at the card — not the chat — and the rows that are yours glow once; the
card coming on screen in a visible tab reads it, on all your Macs. You, a name of its own, and
someone who isn't on the canvas are told nothing; taking someone off tells no one.

**Stored as a note**, so every Copper shows it: a `sticky` with `view: "checklist"` whose text is
the list, in the markdown any note draws as task boxes —

```
### Going
- [ ] Ann
- [x] Ada Lovelace
- [x] Bob · No
  > Back from Lisbon on the 4th;
  > can do the week after.
  @Collin Rijock
  @Ada Lovelace
```

The first `#`/`##`/`###` heading is the title and each `- [ ]` / `- [x]` line a row. `columns` is a
prop; with several, a pick is the line's ` · Column` suffix, and a ticked line with no (or an
unknown) suffix is the first column — that is how an older Copper's tick reads. A click rewrites
only its own line (box and suffix) through the note's `Y.Text`, so ticks on different rows from
old and new clients at the same moment all stick. Who picked and when are kept beside it
(`who:<label>` on the shape) and shown only while they agree with the text. Copper
1.0.20261006.28 and older draw the same shape as a note with clickable task boxes; their ticks
show on the card and the card's on the note. A row's comment is the indented `>` lines right under
its task line (a blank comment line is a bare `  >`; no comment, no lines): it moves with its row
when rows are picked, renamed or reordered, goes when the row is removed, is never read as a row or
a title, and an older Copper shows it as a quote under the item. Writing it changes only the
characters of its own lines, so comments on different rows — or different lines of one — from two
Coppers at once both stick; a first comment goes in after the row's line break, so a pick or a
rename of the same row at the same moment stays on the row's line. Who last wrote it and when sit
beside it (`noteBy:<label>`) and follow a rename. A row's assignees are one indented `@Name` line
each, after its comment (`@ Name`, with a space, reads the same; a name written twice is one
person). After the comment, not before it, because Copper 1.0.20261012.49 and older end a row's
block at its first line that is not a `>` line: there the comment still reads as the row's and
only the names are skipped (its comment, pick and rename writes leave them where they are). A
Copper from before checklists continues the list item with the line, so it shows *Write the
release notes @Grace Hopper*. Adding or removing someone changes only the characters of their own
line; a first assignee under a row with only its line goes in after that line's break (as a first
comment does), under a comment at the comment's end. Who they are — the cloud user id and email of
someone picked from the canvas's people — and who assigned them, when, sit beside the note under
`assignees:<label>` (`[{name, id?, email?, by?, byId?, at?}]`), follow a rename, go with the row,
and count only for a name the text still has: rename *@Grace Hopper* by hand in an older Copper
and she is a name of her own. A face shows the person's name on the canvas now when the id is
theirs, so a renamed account reads right without touching the text. Model and rules:
`Canvas/src/canvas/checklist.ts` and `checklist-text.ts`; the picker's list is
`Canvas/src/canvas/assignees.ts`, the card's faces and picker `components/ChecklistPeople.tsx`.

Agents add one with `{type:'checklist', title, columns?, rows:['Ann', …], picks?:{'Ann':'Yes'},
notes?:{'Ann':'Back at 6'}, assignees?:{'Fix login':['Grace Hopper', 'ann@example.com']}}` and
update `picks`, `notes` and `assignees` by row label (`null` clears; an `assignees` list replaces
the row's people, and who stays keeps who assigned them), `rows` (each kept row keeps its pick,
comment and assignees by label), `columns` and `title` (each an edit of the text). An assignee is
named by name, email or cloud user id and found among the canvas's people (exactly, or by the
start of one person's name — Copper reads the member list first when the ops carry `assignees`);
anyone else is a name of their own (an email kept as both). Someone newly assigned on a shared
canvas is told as above. `{op:'update', id, patch:{view:'checklist', columns?:[…]}}` turns a note that already holds
a heading and a task list into a card in place — the text, and so its ticks, untouched;
`view: null` makes it a plain note again. `canvas_read` gives `view`, `title`, `columns`,
`rows:[{label, pick, by?, at?, note?, noteBy?, noteAt?, assignees?:[{name, id?, email?}]}]` (`note`
only for a row with a comment, cut at 500 characters unless `full`; `assignees` only for a row with
someone on it, `id` their cloud user id), `tally` and the `text`. `./bench --world W canvas
checklist [SHAPE]` reads them, `canvas check SHAPE COL ROW…` clicks a box with real mouse input,
`canvas assign SHAPE ROW…` moves the pointer onto a row and clicks its person button (or faces), and
`canvas picker` says what the open picker lists and who it ticks (`CanvasChecklistBench.swift`).

The first cut stored a checklist as its own `type: "checklist"` (picks under `pick:<rowId>`);
copper-cloud 0.6.0's REST `/ops` still makes those, and this page still draws, clicks and
updates them; their row comments sit under `note:<rowId>` (`{text, by, byId, at}`) and their
assignees under `assignees:<rowId>` (the same list as a note's, names and all), and a row that goes
takes both. Older Coppers don't draw that type at all.

## Timelines

A timeline card (the toolbar's calendar tool or `G`, or an agent's `{type:'timeline'}`) is a
title, a date range with a step — day, week, month, quarter or year — and the things along it. A
new one runs from today to three months out, weekly, at 880 × 300, with its title ready to type.
The card is one level axis with a small dot at every step and a muted label under it (labels thin
out before they would touch; a year, or a month on a daily card, reads a little stronger where it
changes), a thin *Today* line when today is in range, and three kinds of item:

- **Notes**: a dot on the axis, a short stem, and a label chip above the line.
- **Bubbles**: a note with a markdown body — a small card (up to 240 wide) with its label in bold
  and the body drawn as a note draws it; a long body is cut with a fade, and opening the item shows
  it whole.
- **Sections**: a span of days, a rounded band in a colour under the axis with its name inside
  (cut with an ellipsis when tight). Sections that overlap stack in lanes; one that runs past the
  range shows a square edge on that side.

Notes and bubbles stack in tiers above the axis — packed left to right so no two boxes touch, and
a box steps aside rather than sit in another item's stem where it can; what doesn't fit in about
200 board units goes below the sections. The card is never shorter than that needs (it grows as
items arrive, and a resize stops there); which tiers go above depends only on the content and the
width, so a taller card only adds room.

**Working it** — anyone who can edit, selected or not, no edit mode. Hovering the axis shows a
ghost dot on the day under the pointer with its date (*Tue, Oct 14*); a click there opens a small
popover for a **Note** (a label) or a **Bubble** (a label and a body), or *Section from here*;
Return adds it (⌘Return in the body), Escape cancels, and a click elsewhere keeps what was typed.
Dragging along the axis selects a span with a live readout (*Oct 20 – Nov 3 · 15 days*); on
release a name, an end date and the palette make it a section. A click on an item opens its
editor: label, body, date (or start and end), colour, Note ⇄ Bubble, Delete; only what was
changed is written, on Done or Return. Drag a dot or its chip to move it (snapped to a day, its
date shown under it); drag a section's body to shift it or its ends to stretch it. A focused item
takes ←/→ (a day; ⇧ a step), Return (open) and Delete. While the card is selected its header
shows **Start**, **End** (native date fields; a half-typed year is never written) and the
**Step** menu. Items outside the range are kept and counted (*+2 outside range*), never deleted.
Every edit is one ⌘Z step; a read-only board shows everything, and a click on an item shows all
of it. ⌘F finds a timeline by its title, labels and bubbles.

**Stored as a note**, so every Copper shows it: a `sticky` with `view: "timeline"` whose text is
the timeline —

```
### Q4 launch
2026-10-01 → 2026-12-31 · weekly

- 2026-10-14 · Kickoff
- 2026-10-20 → 2026-11-03 · Build sprint · blue
- 2026-11-18 · Launch review · purple
  > Bring the **numbers**,
  > and the pricing deck.
```

The first heading is the title; the first `start → end · step` line (`daily` … `yearly`; `->`
works too, and without a step word it is weekly) is the range; each `- date` line an item — one
date a pin, `date → end` a section — with ` · label` and, last, an optional ` · colour` from the
palette (yellow, pink, blue, green, purple, gray). A pin with indented `>` lines under it is a
bubble, their text its body (a blank line is a bare `  >`); without, a note. Dates are ISO days,
so nobody misreads 03/04. Items are written in date order. Any other line — prose, a half-typed
date — is kept as it is and drawn by nobody. Every write changes only the characters of its own
lines (the title's, the range's, or one item's), so edits to different items from two Coppers at
once both land, and an item moved past its neighbours is lifted out and put back in its place. An
older Copper shows a readable note: the heading, the range, a list, bubbles as quotes. Model and
rules: `Canvas/src/canvas/timeline-text.ts`, `timeline.ts`; layout: `timeline-layout.ts`.

Agents add one with `{type:'timeline', title?, start, end, step?, items?:[{date, end?, label,
text?, color?}]}` (`text` makes a bubble, `end` a section; without `start`/`end` the items' span
is the range, and without `step` one suits the span). `update` takes the same fields — `items`
replaces the list — plus `addItems:[…]` and `editItems:{ref: patch | null}` to change or remove
(`null`) single items, where `ref` is `"YYYY-MM-DD · label"`, a label (any case), a date (its first
item) or an index, and a patch is `{date?, end?, label?, text?, color?}` (`end:null` makes a pin,
`text:null` a note). An update whose refs miss writes none of its edits. `{view:'timeline'}` /
`view:null` convert a note in place, its text untouched. `canvas_read` gives `view`, `title`,
`start`, `end`, `step` and `items:[{date, end?, label, text?, color?, kind:'note'|'bubble'|
'section'}]`, with the `text`.

## Comments on shapes

*Page: `Canvas/src/canvas/comments.ts` (model and writes), `components/Comments.tsx` (pins, thread
popover, Comments panel, right-click menu), wired in `components/Board.tsx`.*

Figma- / Google Docs-style threads on any shape — above all a frame, which on a deck board is a
whole slide or section. **Starting one:** select one shape and choose **Comment** in the selection
bar, right-click it and choose **Comment**, or press **⌥⌘M** (Google Docs' *Insert comment*; `C` is
the chat here, so Figma's `C` was taken). ⌥⌘M also works while typing in the shape: the edit ends
and the comment starts. A new thread opens a small popover beside the shape's top-right corner with
the composer focused; Return posts (Shift+Return is a new line), Escape or Cancel closes it, and an
unsent draft is kept for that shape until the page reloads. The view flies to the shape first when
it is off screen or under the panel.

**On the board.** Each shape with open threads has one quiet pin just off its top-right corner —
the author's initials for one thread, a comment icon and a count for several — at the same size at
every zoom, moving with the shape (also while it is dragged). A click opens the thread (or, for
several, the list of that shape's threads, each opening its own). Resolved threads have no pin
unless open.

**A thread** is its messages in order — avatar, name, how long ago (the full time on hover),
*edited* when it was — and a reply field at the bottom that grows to about seven lines and then
scrolls in itself. Anyone who can edit can reply; authors can edit (in place, Return saves, Escape
cancels) and delete their own messages, from buttons that show on hover or keyboard focus. A
deleted first message leaves *Comment deleted* above the replies; a thread with every message
deleted stops showing. **Resolve** (✓ in the header) hides its pin and offers *Undo* for a moment;
**Reopen** (↺) or any new reply brings it back. Words wrap anywhere, a link opens in a tab, and
the popover keeps inside the window: beside the pin when there is room, else on its other side, at
most 560 px tall with the messages scrolling.

**Comments panel.** The speech-bubble button beside chat and search shows it on the board's right:
open threads first (newest activity first), then a collapsed *Resolved* group. Each row says which
shape it is on (a frame's title, a note's first line, a checklist's title…), who started it, the
first message (two lines), the reply count and the last activity. A click flies to the shape,
selects it and opens the thread beside it. A thread whose shape was deleted stays listed as *on a
deleted shape* with the name the shape had, opens beside the panel, and comes back to the shape if
an undo restores it. **Search** (⌘F) finds comments by their words too; picking one opens its thread.

**Stored apart from the shapes.** A top-level `Y.Map` named `comments` in the canvas document:

```
comments: Y.Map<threadId, Y.Map{
  id, anchor (shape id), anchorName,             // the shape's name when last written, for when it is gone
  by, byId, at,                                  // who started it (the board's identity, as `by`/`byId` on shapes and chat), ms
  resolved, resolvedBy?, resolvedById?, resolvedAt?,
  messages: Y.Array<Y.Map{id, by, byId, at, text, editedAt?, deleted?}>
}>
```

Every write touches only its own keys, so two Coppers merge: two replies at once are two pushes
(both land, in the same order everywhere); resolving sets three keys on the thread while a reply
pushes onto its list (both land); an edit sets `text`/`editedAt` on its message; a delete leaves a
tombstone (`deleted: true`, text cleared), so a reply racing it is never lost. A reply to a resolved
thread reopens it (as Docs and Figma do). Shape writes never touch the map and comment writes never
touch a shape. The board's undo manager is scoped to `shapes`, so ⌘Z never takes back a comment and
a comment never pushes a shape edit off the undo stack (origin `comment`; agents' ops use `agent`
but stay out of undo the same way). The map goes out with every other update — `updates.log`,
`snapshot.bin` (`exportState` is the whole document), the room — and older Coppers carry it
unread. Copying, duplicating or pasting a shape doesn't copy its threads (a copy is a new shape);
deleting a shape keeps them. Messages are plain text, at most 10,000 characters. @mentions are not
part of comments (the chat's mentions and notifications are chat-only).

**Agents.** `canvas_read` carries `comments:[{id, anchor, anchorDeleted?, resolved, resolvedBy?,
messages:[{id, by, at, text, edited?}]}]` (deleted messages left out, text cut at 500 unless
`full`; with `ids`/`inView` only threads on the shapes returned). `canvas_apply` takes
`{op:'comment', on: shapeId, text, id?}` (a new thread; `ids[i]` is its id), `{op:'reply', thread,
text}` and `{op:'resolve', thread, resolved?: true|false}`, attributed to the caller like any write.
copper-cloud's REST `/ops` doesn't know these ops; its rooms persist and relay the map untouched.

## Live web frames

A link on the board can show the site itself instead of its card: an `<iframe>` under a slim title
bar, which you and everyone else on the board can use at the same time.

- **Making one.** The link prompt (the link tool, or `L`) has **Live** (⌥↵) beside Add; a link you
  paste or drop lands as a card with a *Link added · Show live* toast; any link card's selection bar
  has **Show live** (and a live one **Show as card**). Agents add `{type:'web', url}` (or a link
  with `live:true`; `embed` and `iframe` are accepted spellings); it is 960×640 by default and
  never smaller than 320×200. A live link is still a `link` in the document — a page from before
  frames shows it as a card and keeps the flag.
- **Using one.** Until it is in use a frame is a shape like any other: a transparent shield lies
  over the page, so it selects, drags, resizes, marquees and zooms with the board. Click the
  selected frame (or double-click it, or ↵) and the shield comes off: the page scrolls, takes
  clicks and the keyboard. **Esc** (when the site didn't use it), a click on the board or another
  shape gives the board back. The bar has Back / Forward (this frame's own pages, not the board's
  history), Reload, the address (editable while in use), **Sign in**, **Open in a tab** and **Show
  as card**.
- **Together.** Where a frame is — its `url`, `title` and `favicon` — is the shape's, so it syncs
  like any edit: when the person using a frame follows a link, everyone else's frame goes there
  too. Only the person using a frame writes its address (a frame that is following someone, or
  redirecting on its own — to a sign-in page, another locale — never writes it), and browsing is
  never an undo step. Whoever is using a frame shows on it: a ring and a name tag in their colour.
  Scroll position, what is typed into the page and the page's own state are each person's.
- **Cheap when idle.** At most six frames have a real iframe at once: the one in use, then the
  ones on screen and at least 260 px wide, nearest the middle first; the rest show a placeholder
  (favicon, title, host) until you come closer.

### Privacy: one address, your own cookies

What a live frame shares is **where it is, never who it is signed in as.** Each person's Copper
loads the site with their own cookie jar — the board's view uses the store of the space it was
opened in (its profile's, if the space wears one), the same one a tab there uses. Nobody's
cookies, storage or page contents travel through the board; the board only carries the address
and title, which everyone on it can read (the same as a link card). So a private page — a doc,
an inbox — shows each person their own view of it, or a sign-in page if they have no access.

### Which sites stay signed out, and why

The board is a local file (`file://`), so to the browser every site in a frame is a
**third-party, cross-site** frame. WebKit then sends a frame only the cookies marked
`SameSite=None` (and unmarked ones); `SameSite=Lax` and `Strict` cookies — which most sign-ins
use now — are never sent to a frame, whatever the board does, and storage (localStorage,
IndexedDB) is partitioned, so the frame doesn't see what the site stored in a tab. Measured on
macOS 26 with WebKit's own settings:

- Public pages (Wikipedia, docs, news, dashboards with public links) work fully.
- Sites whose session cookie is `SameSite=None` (apps made to be embedded often are) are signed
  in as you, once you have signed in to them in a tab.
- Sites with Lax/Strict session cookies (GitHub and Google among them) show signed out in a
  frame however you sign in. **Sign in** in the bar opens the frame's page in a tab — where it is
  the site itself, with every cookie, your passwords and passkeys — and the frame reloads when you
  come back to the board, picking up whatever of that sign-in a frame may carry. For the rest,
  **Open in a tab**. Passwords and passkeys are not offered inside a frame (Copper's passkeys
  answer only the site you are on, and the board is not that site).
- Sites that refuse to be framed (`X-Frame-Options`, `frame-ancestors`) load anyway in the board —
  the board's view, and only it, turns on WebKit's `IgnoreIframeEmbeddingProtectionsEnabled`. A
  page that still shows nothing — one that hides itself when framed, a load that never arrives —
  gets a card: *\<host> doesn't allow embedding · Open in tab · Try again · Show as card*.

What would change it, and why Copper doesn't: turning off WebKit's third-party cookie blocking
(`_setThirdPartyCookieBlockingMode:` on the store) works, but for the whole store — every tab of
the space, every tracker on every page — so it stays off. Serving the board from a custom scheme
instead of `file://` changes nothing: the board would still be cross-site to every site.
`_setShouldRelaxThirdPartyCookieBlocking:` is Safari's alone (WebKit throws for anyone else), and
the `IsThirdPartyCookieBlockingDisabled` feature has no effect for an app.

### How it works

- **Page** (`Canvas/src/canvas/frames.ts`, `components/WebFrame.tsx`): the iframe is sandboxed
  (`allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox
  allow-modals allow-downloads allow-storage-access-by-user-activation
  allow-top-navigation-by-user-activation` — never `allow-top-navigation`, so a frame-buster can't
  take the tab), `allow="fullscreen; clipboard-write; autoplay; encrypted-media;
  picture-in-picture"` (no camera, mic or location), and named `copper-frame:<shape id>:<nonce>`;
  the nonce is made per mount and never leaves the page. The page's CSP allows `frame-src https:
  http:` and still `connect-src 'none'`.
- **Host** (`Sources/Search/Fork/Canvas/CanvasFrames.swift`): a user script in every subframe of
  the board, in a content world of its own (`CopperCanvasFrames`, out of the site's reach), reads
  the frame's name at document start — before the site's scripts can change it — and, only in a
  frame directly on the board with a `copper-frame:` name, reports to its own handler
  (`copperFrame`): `nav` (address, title, https icon; on load, history changes, and a 1 s check
  while visible), `escape` (Esc the site didn't use) and `blank` (the page hid itself). The
  handler drops anything from the main frame or another web view, an address not on the origin
  WebKit says the frame is on, or a name that isn't the board's, and hands the rest to the page:
  `copperCanvas.frameEvent({name, kind, url?, title?, icon?})`. After `init` the host says
  `copperCanvas.frameHost({reports: true})`; from then on a frame that loads without reporting
  shows the "doesn't allow embedding" card. The `canvas` handler still answers the main frame
  only, so a framed site can't speak for the board.
- **Popups.** A window a frame opens (`window.open`, "Sign in with…") and a `target=_blank` or
  `_top` link are ordinary tabs in front (`CanvasHost.popup`, `CanvasHost.decide`), never a view
  built from the board's configuration; the opener link is lost, so a popup sign-in finishes in
  the tab.
- **Not in a frame:** the ad blocker (a board's view carries no content rules), Copper's password
  and passkey helpers, extensions, and the hide-something picker — a frame is the site as WebKit
  shows it. A frame that is a PDF or another document no script runs in may show the "doesn't
  allow embedding" card; Open in tab shows it.
- `./bench canvas frames [ID]` shows what the host passed on, whether the embedding preference is
  on, and the board's cookie store.

## Where things are kept

`Application Support/Copper/canvas/` (a probe world's own folder under `SEARCH_PROBE`):

| file | what |
|---|---|
| `canvases.json` | the registry: `[{id, name, kind: personal\|shared\|local, remoteId?, createdAt, updatedAt, role?, owner?, members?, account?}]` |
| `me.json` | this Mac's persona (stable id + colour, shown when signed out) and which account the local Personal history was first bound to |
| `<id>/updates.log` | every Yjs update the page reported **and every update the room handed the page** (a sync message's SyncStep2 / update payload, kept as it is delivered), in order: 4-byte big-endian length + bytes |
| `<id>/snapshot.bin` | the whole document as one update, written when the log passes 2 MB or 500 entries (the page's `exportState()`), after which the log keeps only what came after |

Opening a canvas hands the page `snapshot.bin` as `init.state`, then every logged update through
`applyUpdate`. Yjs makes a repeated update harmless, so compaction only ever errs on the side of
keeping too much (it drops the entries that existed when the export was *asked for*). A record cut
short by a crash is trimmed on the next read.

Personal belongs to one account: the first account it is relayed to is remembered, and a
*different* account signing in on the same Mac gets a fresh local Personal history
(`personal-<userId>/`) so two people's private boards never merge.

**Personal syncs only when chosen.** Its room is a sync domain like the others —
`CloudSync.Domain.canvas`, "Personal canvas" in Settings › Cloud › Choose what syncs, included in
`cloud sync on all`, off until picked, paused by *Turn off* and by signing out. The switch is kept
in `cloud-sync.json` (`canvas`, beside the sync bases; `Cloud.SyncPrefs` in cloud.json has no
field for it yet). `Canvases.room(for:)` gives Personal a room only when
`CloudSync.shared.syncs(.canvas)` and the row's `account` is the account signed in; with every
switch off nothing on the Personal board leaves the Mac. Shared canvases are cloud documents by
definition and keep their room whenever their account is signed in.

## What happened to easels

Copper had a second board, **Easels** (local only, its own Yjs schema, served from a
`copper-easel://` scheme of its own). It was folded into Canvas: Canvas is the engine — it syncs,
shares, invites and has the agent tools — and Easels gave it its ways in, its row and its lean tab
(the sections above). The Easel engine, its scheme and its web bundle are gone; what is left is
`CanvasImport.swift`, which brings each easel a Mac still has into a canvas the first time a
build with Canvas-only starts:

1. **Before the session is restored**, every easel in `easels/index.json` that
   `easels/migrated.json` doesn't list gets a **local canvas with the same name and dates** (an
   easel still called *Untitled Easel* becomes *Untitled canvas*), and the mapping is written down.
   From then on an easel's old address — in the session file, a favourite, a bookmark, a link, the
   address field — is that canvas's; one whose easel never became a canvas is dropped from the
   session ("That easel isn't in Canvas yet" when opened by hand).
2. **A moment after the window is up**, each easel not yet done is loaded into its canvas's page
   in a view nobody sees (the same configuration, bridge and `CanvasHost` a canvas tab uses, so
   every update goes to the canvas's history the ordinary way), and the page is handed the old
   document and its pictures: `copperCanvas.importLegacy({doc: <base64 of doc.yjs>, files:
   {<fileId>: <data: URL>}, title})`, which turns stickies, frames (title and picture), arrows
   (`from`/`to` = `shape:<id>`, the label) into canvas shapes in one transaction and answers
   `{imported, skipped, error?, already?}`. The page is then checkpointed (its whole document
   written as `snapshot.bin`) and let go. Fifteen seconds an easel at most; one at a time.
3. An easel is **done** when its board came over — wholly, or as far as it ever will (a picture
   that can't be read is said in `error`, not retried). A failure (a corrupt `doc.yjs`, a page
   that didn't come up) is logged (`canvas` category, "easel import: …"), stays not done, and is
   tried again on the next launch into the same canvas. The page remembers which documents it has
   imported (`meta.importedLegacy`), so a retry never puts a board's shapes on twice. A canvas
   deleted after its easel was done is never brought back.

**The easel folders are never deleted.** `easels/` (index, `viewer.json`, every `<id>/doc.yjs` and
`files/`) stays where it was, beside `migrated.json`:

```
easels/migrated.json   {"easels": {<easel id>: {canvas, done, imported, skipped, error?, tries, at}}}
```

Removing an entry (or the file) and relaunching runs that easel's import again — into its old
canvas if it still exists, else a new one. `bench canvas import` shows the records;
`bench canvas import run` runs whatever is not done, now.

## The cloud

With a cloud linked and signed in (`Fork/Cloud/`), `GET /v1/canvases` fills the list (Personal is
matched to the server's `kind=personal` canvas) and `GET /v1/invites` the invites — refreshed when
the card opens and on every `canvas` event from `/v1/sync/events`. A canvas with a room is relayed
over a pinned `CloudSocket` to `wss://<host>/v1/canvases/<id>/ws` (backoff 1 → 30 s, ±30 % jitter).
The page runs y-websocket's provider over a bridge socket; Copper only moves frames, and holds the
server's greeting (its SyncStep1 + awareness) until the page's socket is open — the SyncStep1 is
what makes the page send what the room is missing, which is how an offline Personal history or an
edit made while the server was down reaches it. A new page socket (`wsOpen`) gets a fresh
connection, so it always gets a greeting of its own; `wsClose` drops the room. Live collaborators
are counted from the awareness frames on the wire (a frame may hold several y-protocol messages),
**by person** — the state's `user.id` — so you in a second tab or on another Mac are not a
collaborator; a state not renewed for 45 s has gone. Sign-in or sign-out reloads open canvas pages
so their provider starts or stops. After a couple of connections that never open (a revoked
member, a deleted canvas — `CloudSocket` doesn't surface the 4403/4404 close codes) the list is
read again, and a canvas gone from it closes its tabs.

**Which room, for whom.** A page is told its room once, in `init`; the host remembers that room id
(`roomId`). Signing in or out, another account, the Personal switch (`CloudSync.didChange`) and
every list read (`Canvases.refresh`) compare it with what `room(for:)` says now; a page whose room
is no longer the right one — or whose history is another account's (`storeKey`) — is
**checkpointed and reloaded** (`restartPage`), so its provider starts, stops or moves rooms. The
list is keyed to the account it was read for: a different account signing in starts with no list
(the first page open waits up to 1.5 s for it) and an answer that arrives after a switch is
dropped and asked for again. The 20 s sweeper repeats the comparison (a notice missed) and gives a
live page that lost its room a new one, so a page never stays on "online, no room".

**Nothing a collaborator wrote is lost to a disconnect.** The page reports only its own changes;
what its provider applied from the room it never reports. So the host keeps those itself, as it
hands them over (`CanvasHost.hand` → `CanvasStore.appendRemote`, deduplicated across two tabs on
one canvas, and handed to the sibling tab too): a sync message's SyncStep2 or update payload is a
whole v1 Yjs update, the same as the page's own. Frames for a socket that never opened are not
kept (the page never had them; the next sync brings them). Before a page is let go for a room
change, the whole document is exported (`exportState`) and written as `snapshot.bin` by atomic
rename (`checkpoint`, two seconds at most) and the store's queue is flushed; closing a tab,
navigating it away and quitting (⌘Q, SIGTERM in a probe, an update's relaunch:
`NSApplication.willTerminateNotification` → `CanvasStore.flushAll`) flush too. Compaction stays
safe because every update counted in the log was *posted* to the page before the export is asked
for (`post` issues the call at once, and WebKit runs one view's calls in order). While a room has
brought anything in the host still folds the log into a fresh snapshot every two minutes.

**The page's status line** is told with `copperCanvas.setStatus({mode, pending})` whenever it
changes (when the page has the function): `local` (Personal or a local canvas, on this Mac by
design), `personal-synced`, `shared-live` (room open and the server's SyncStep2 received) or
`shared-offline` (a shared board with no room: signed out, disconnected, the server away), and
`pending` — changes made here since the room last confirmed a sync.

Create `POST /v1/canvases {name}`, rename `PATCH /v1/canvases/:id`, delete `DELETE
/v1/canvases/:id` (owner), leave `DELETE /v1/canvases/:id/members/<me>`, members `GET
/v1/canvases/:id/members`, invite `POST /v1/canvases/:id/invites {email}` (on 0.5.0 a second one
for the same address is a reminder: `200` with `nudged`), the invites waiting on a canvas `GET
/v1/canvases/:id/invites`, withdraw one `DELETE /v1/canvases/:id/invites/:invite_id` (0.5.0), answer
`POST /v1/invites/:id/accept|decline`.

## The page ↔ host bridge

The page is one self-contained file, `Sources/Search/Fork/Canvas/Resources/canvas.html`
(`build.sh` copies a newer `Canvas/dist/canvas.html` over it), loaded with
`loadFileURL(…canvas.html?id=<id>, allowingReadAccessTo: <its folder>)`. There is no URL scheme
handler: `copper://canvas/…` is caught in the browser's navigation delegate
(`CanvasHost.decide`) and the tab keeps the copper:// address. Canvas tabs opened through
`Browser.open` or the session get their own `WKWebViewConfiguration` with the `canvas` handler on
it before the view exists and no extensions attached; any other tab told to go to a canvas gets
the handler when the page is loaded into it. The handler answers only the bundled page's main
frame in a web view that is a canvas host's.

Page → host, `window.webkit.messageHandlers.canvas.postMessage({...})`:

| message | host does |
|---|---|
| `{type:"ready"}` | `init(...)`, then `applyUpdate` for each logged update, `theme(...)`, `document.title`, then opens the room if there is one |
| `{type:"update", b64}` | appends to `updates.log`, hands it to any other tab on the same canvas; compacts when due |
| `{type:"selection", ids}` | kept for the tools |
| `{type:"share"}` | the page's own Share button was clicked — opens the native Share sheet |
| `{type:"presence", people:[{id,name,color,kind}]}` | debounced (≤500 ms) on every change; kept per canvas for the Share sheet's "N here now" faces |
| `{type:"ws", b64}` | sent on the room's socket |
| `{type:"wsOpen"}` / `{type:"wsClose"}` | the page's socket wants / no longer wants the room — answered with `wsState("open")` when the room is up |
| `{type:"openUrl", url}` | http(s) in a new tab in front; `copper://canvas/…` switches to that canvas |
| `{type:"log", level, msg}` | os_log (subsystem `com.collinrijock.copper`, category `canvas`) |

Host → page, always with `callAsyncJavaScript(arguments:)` in the page world (values travel as
arguments, never pasted into source), so a function may return a value or a promise:

- `copperCanvas.init({docId, name, kind, me:{id,name,color}, state: b64|null, online, readOnly})`
- `copperCanvas.applyUpdate(b64)`, `wsMessage(b64)`, `wsState("open"|"closed")`
- `copperCanvas.apply(opsJsonString, who) → resultJson` — `who` is `{id, name, color}`
- `copperCanvas.read('{"full":false}') → json`
- `copperCanvas.select(ids)`, `zoomTo(ids)`, `setAgent({id,name,color,cursor,status})`,
  `theme("light"|"dark")` (pushed again whenever the view's appearance changes)
- `copperCanvas.exportState() → b64` (optional; without it the log is simply never compacted)
- `copperCanvas.setStatus({mode: "local"|"personal-synced"|"shared-live"|"shared-offline", pending})`
  (optional; called only when `typeof setStatus === 'function'`)
- `copperCanvas.setShare({canShare, members?, reason?})` — shows/enables the page's own Share
  button; called after `ready` and whenever the entry, its membership or the cloud link changes
  (guarded: `typeof setShare === 'function'`, for a bundled page older than this)
- `copperCanvas.frameEvent({name, kind:"nav"|"escape"|"blank", url?, title?, icon?}) → bool` and
  `frameHost({reports})` — live web frames' reports ([Live web frames](#live-web-frames)); from
  the `copperFrame` handler, in its own content world, never the `canvas` one
- `copperCanvas.presence() → [{id,name,color,kind,cursor}]` (read, not pushed — used by `bench
  canvas presence` and anything checking live cursors, not just the Share sheet's faces)

`me` is the cloud account (`userId`, display name) when signed in, else this Mac's persona (the
macOS full name, a stable colour). `docId` is the server's canvas id when there is one.

## The tools (⌘E agent, MCP, `copper call`)

All in `CanvasTools.swift`, dispatched from `Tools.call`, so all three surfaces get the same
behaviour; every call shows in the Driver pane and every write is attributed (`by`) to the caller:
the MCP client's name (`Claude Code`, `phi`, `copper CLI`…), **Copper agent** for ⌘E, or `as`.
The agent's presence (`setAgent`, cursor on the last shape it touched) is a two-second lease:
each operation renews it, then the cursor fades and its face leaves the collaborator list.
Closing the page or disconnecting releases that page's agent leases; stale leases from a lost
peer are hidden on expiry too. Human collaborators and the shapes' author attribution stay.

| tool | arguments | answer |
|---|---|---|
| `canvas_list` | — | `{canvases:[{id,name,kind,open,live,collaborators,url,updatedAt,role?,members?}], cloud}` |
| `canvas_open` | `id` (or name) \| `name`, `foreground?` | the canvas's summary, once its page is up (background by default) |
| `canvas_read` | `id?`, `full?` | `{canvas:{id,name,kind}, viewport, shapes:[{id,type,x,y,w,h,color,text\|title\|label\|url,by}], comments:[{id,anchor,resolved,messages}], agents, selection}` |
| `canvas_apply` | `id?`, `ops` (required), `as?` | `{applied, ids, errors}` |
| `canvas_select` | `id?`, `shapeIds` | — |
| `canvas_focus` | `id?`, `shapeIds` | — (zooms the view to them) |
| `canvas_create` | `name` | the new canvas's summary (shared when signed in, local otherwise) |
| `canvas_invite` | `id`, `email` | — (cloud only; Personal and local canvases refuse with a reason) |
| `canvas_share_link` | `id` | `{link, webLink}` — makes the canvas's invite link once, then reuses it |
| `canvas_join` | `link` | opens a `copper://canvas/join/...` or `https://<cloud>/join/...` link in this window, as if it had been clicked |
| `canvas_screenshot` | `id?` | PNG of the canvas tab |

`id?` omitted means the canvas tab in front, else Personal. Every schema also takes `reason`.
Each call leaves its one line in `Tools.summary` — *220 operations applied on Roadmap*, *Read 7
shapes on Personal*, *Invited ada@example.com to Roadmap*, *Selected 2 shapes…*, *Created …* —
which rides as `_meta.summary` and is what the Driver pane's row says after the arrow (MCP and the
⌘E agent alike). Canvas tools never report "page changed / no change": they change a board, not
the page.
Ops: `add {shape:{type, x?, y?, w?, h?, color?, …}}` (no x/y → free space near the view),
`update {id, patch}`, `move {id, dx, dy}`, `resize {id, w, h}`, `delete {id}`, `connect {from, to,
label?}`, `comment {on, text}`, `reply {thread, text}`, `resolve {thread, resolved?}` (comment threads,
[Comments on shapes](#comments-on-shapes)), `clear {confirm:true}`. Colours: yellow, pink, blue, green, purple, gray, white, `#hex`.

```sh
copper tools | grep canvas_
copper call canvas_apply '{"reason":"jot it down","ops":[{"op":"add","shape":{"type":"sticky","text":"hello"}}]}'
copper call canvas_read '{"reason":"what is on the board"}'
copper call canvas_share_link '{"reason":"invite a teammate","id":"Roadmap"}'
```

## Sharing a canvas (invite links, Share sheet, join flow)

*Native Swift: `Sources/Search/Fork/Canvas/CanvasShare.swift`. Server:
`copper-cloud`'s `/v1/canvases/:id/links`, `/v1/canvas-links/:token`, `/join/:token` (not under
`/v1`, no instance-key gate — a tiny static landing page), `/v1/people`.*

**Link formats.** Copy invite link gives `copper://canvas/join/<token>?cloud=<host[:port]>&n=<url-encoded
name>`; Copy web link gives `https://<host[:port]>/join/<token>`. `copper` is registered as its own
macOS URL scheme (`build.sh`'s Info.plist — a second `CFBundleURLTypes` entry, "Copper link",
separate from the "Web address" http/https one, `CFBundleTypeRole` Viewer) alongside http/https, so
mail clients, Slack, anywhere a link can be clicked, hands it to Copper. Canvas ids are UUIDs or
`personal`, so `copper://canvas/join/...` can never collide with `copper://canvas/<id>`.

**The Share sheet** (`CanvasShareSheet`) opens from the page's own Share button (the `share`
bridge message), the sidebar canvas row's **Share…** (replacing the old **Invite…**), and the
command bar's **Share Canvas**. It shows who is live right now (the canvas's `presence`
messages: *Only you here* with the canvas open and nobody else in it, *N here now* counting you,
nothing when it isn't open here and nobody is in it), **Copy invite link** / **Copy web link** (the
token is made once through `POST /v1/canvases/:id/links` and cached per canvas in
`canvas/share-links.json`, 0600, never the keychain — later copies reuse it), **People on this
cloud** (*Search people or type an email*: debounced `GET /v1/people?q=`; a typed address that
isn't a member gets its own row; every Invite is the email-invite path, `POST
/v1/canvases/:id/invites`), **Members** (owner can remove), **Invited** (the invites waiting on
this canvas, `GET /v1/canvases/:id/invites`, read with the members when the sheet opens and on
every list refresh — someone accepting or declining shows while it is open), and **Reset link**
(owner; `DELETE /v1/canvases/:id/links`, drops the cached token). A local or Personal canvas
explains it can't be shared and offers **New shared canvas** or **Connect to Copper Cloud**
instead. The sheet's state is a `CanvasShareModel` that `CanvasUI.mode` makes and drops, so
`bench canvas ui share state|type TEXT|invite [EMAIL] [--instant]|resend EMAIL|withdraw
EMAIL|reload|copy` reads and drives the same sheet a person sees.

**Where each person stands.** Every person's row — a directory row, the typed address's row, an
Invited row — says one of: **You**; **Owner** / **Member** (with the role on hover); **Invited**
(· **Resend** · **×**); or an **Invite** button. Clicking Invite flips the row to *Invited* at once
(a stand-in invite until the server's copy arrives; it goes back, with the reason, if the server
says no) and the line right under the field — above the rows, so a long list never pushes it out
of the card — says what happened: *Invited Ada Lovelace — it's waiting for them in Copper*, or
*Invited dana@example.com — waiting for them to make an account on \<host>* when no account has
that address yet. The rows, Members and Invited scroll together below that line (360 pt at most),
vertically only.

- **Resend** invites the same address again. On copper-cloud 0.5.0 that is a reminder: the server
  stamps the invite's `nudged_at`, answers `"nudged": true` and sends the invitee a `canvas` event,
  so the pill comes back up in their Copper — *Reminded Ada Lovelace*. It reminds someone at most every
  30 s, counting from the invite itself (*Invited Ada Lovelace moments ago — you can remind them in a
  minute*). It is not offered for an address with no account yet (there is no Copper to bring it
  up in; the row's second line says *No account on \<host> yet*). Any member may resend.
- **×** withdraws the invite (`DELETE /v1/canvases/:id/invites/:invite_id`, 0.5.0): the row goes at
  once, the sheet says *Withdrew the invite to Ada Lovelace*, and the invitee's pill and Invitations
  row go on the `invite_revoked` event. Only the canvas's owner, or whoever sent that invite, sees
  it. A refusal is a sentence (*That invite was already answered or withdrawn.*).
- **On a cloud before 0.5.0** (`Cloud.Feature.inviteReminders`, by `/v1/info`'s version) there is
  no Resend and no ×: inviting again reminds nobody there and an invite can't be taken back, so
  the row only says *Invited* (its help: *Waiting for them to join — it's in their Copper*) and
  the Invited list still shows every invite waiting. The confirmation reads the same; whether an
  address has an account is known only from the directory (an address it looked up and didn't
  find: *…waiting for them to make an account on \<host>*).

`canvas_invite` answers in the same words, naming the canvas: *Invited Ada Lovelace to Roadmap*,
*Reminded Ada Lovelace about Roadmap*, *Ada Lovelace was invited to Roadmap moments ago — too soon to
remind them*, or on an older cloud *tim@example.com was already invited to Roadmap*. `canvas_list`
adds `invitations: [{canvas, from}]` while any invite waits for the user's answer.

**Older clouds.** Share links and the people directory arrived in copper-cloud 0.3.0. Copper
reads the instance's version from `GET /v1/info` (`Cloud.serverVersion`, once per link and again
whenever the event stream reconnects; `Cloud.supports(.shareLinks)`), and with the version
unknown takes a bare route-level `404 not_found` from `/v1/people` or a links route as "this
instance hasn't got it" (`Cloud.lacks`). Against an older instance the sheet hides Copy invite
link, Copy web link and Reset link, never calls `/v1/people`, and says one quiet line — *Invite
links need Copper Cloud 0.3.0 — \<host> runs \<version>. You can still invite people by email.* —
with the field titled **Invite by email**. Email invites work on every version. No failure in
the sheet shows the server's own short text ("not found", "conflict"): `Canvases.plain` turns
each refusal into a sentence (an address that isn't one, yourself, someone already a member, a
canvas no longer there, a cloud that can't be reached), and a success reads *Invited \<name> —
it's waiting for them in Copper*.

**The join flow** (`CanvasJoinLink.parse` + `CanvasJoinFlow`) is one parser and one actor reached
from four places: LaunchServices/AppleEvents (`Links.swift`), the address bar (`Browser.arrive` /
`Browser.go`), an in-page link click (`Browser`'s `WKNavigationDelegate`, which cancels the
navigation), and any tab navigating to the `https://.../join/<token>` form when its host\[:port]
is the cloud this Copper is linked to (a different cloud's landing page is left to load as an
ordinary page, which is where its own "Open in Copper" button lives). Not linked, or linked to a
different cloud: Settings › Cloud opens with *"This canvas is on \<host>. Connect to that Copper
Cloud to open it."* Not signed in: the link is remembered (`canvas/pending-join.json`, 0600) and
resumed the moment sign-in completes. Otherwise: `GET /v1/canvas-links/:token` (already a member
→ just open it), else `POST /v1/canvas-links/:token/join`, upsert the returned row, refresh, then
open it in the **key window** (so an external open lands somewhere sane), in front. A 404
`link_not_found` says *"This invite link no longer works — ask for a new one."*; an instance
before 0.3.0 (by its version, or by a bare `not_found` for the route) says *"This Copper Cloud
doesn't support invite links yet (runs \<version>)."* `canvas_join` waits for the outcome and
answers with it.

**Being invited** (`Fork/Canvas/CanvasInvites.swift`). Three places say an invite is waiting, all
reading `Canvases.invites` (`GET /v1/invites`, read again on every `canvas` event — `invited`,
`invite_revoked`, `invite_declined`, `member_added` — and whenever the event stream comes back):

- **The pill** at the window's foot: *"\<sender> invited you to “\<name>” · Open ×"*. It rises
  for every invite waiting the first time the list is read after a launch or a sign-in, for each
  new one after that, and again whenever its sender reminds you (the invite's `nudged_at` moved —
  it then reads *"\<sender> reminded you about “\<name>”"*). **Open** joins and opens the canvas
  in front; **×** is *Not now* — the pill goes, the invite stays under Invitations, and a reminder
  or the next launch brings the pill back. An invite withdrawn or answered on another Mac takes
  its pill with it. The pill is drawn **over the panels** — Settings, History, Downloads,
  Passwords — so signing up in Settings › Cloud no longer hides the invite that was waiting for
  the new account (`CanvasInviteBar`, overlaid after `panels` in `App.swift`; `CanvasInviteSlot`
  keeps its place in `bars`, so the other lines there stack above it).
- **Invitations** in the Canvas card (above), with Decline / **Join**, for as long as it waits,
  and the dot on the door.
- **⌘K**: *Join Canvas · \<name>* for each invite waiting (type *join* or the canvas's name) —
  the way in when the sidebar is off.

An invite can stop being open while it is on screen — joined through the canvas's share link
(copper-cloud marks it accepted), answered on another Mac, withdrawn — and Join or Decline on it
then gets `404` from `POST /v1/invites/:id/accept|decline`. `Canvases.answer` takes that as "no
longer pending", not as an error: the invite leaves the pill, the list and ⌘K, the lists are read
again, and a Join opens the canvas when this account is a member of it already; otherwise the
window says *That invite is no longer open*. Joining through a share link also takes any invite
to that canvas off this Copper at once (`Canvases.drop(canvas:)`), before the lists are read again.

## Chat

*Page: `Canvas/src/canvas/chat/` (model, hub, panel, composer, button, dock, API). Host:
`Sources/Search/Fork/Canvas/CanvasChat.swift` (state, mentions) and `CanvasChatUI.swift` (pill,
notifications, `canvas_chat`, bench). Server: copper-cloud 0.6.0's mentions API.*

**Where.** Only canvases that live on a Copper Cloud — a shared canvas, while signed in. Personal and
local canvases have no chat (`setChat({enabled:false})`; no button, no panel, no shortcut).

**Stored in the canvas.** Messages are a top-level `Y.Array` named `chat` in the canvas document,
plain objects `{id, authorId, authorName, text, mentions:[userId], at (ms), editedAt?, deleted?}`.
A message is appended locally (instant) and goes out with the rest of the board's updates — stored
in `updates.log`, relayed to the room, kept by the server untouched; the board's undo never sees it
(origin `chat`). At most 1000 are kept: the client that appends past the cap deletes the oldest in
the same transaction. Text is at most 4000 characters, plain text only (rendered as text nodes; a
URL becomes a link that opens in a tab). Deleting your own message leaves a tombstone
(`deleted: true`, text and mentions cleared). A mention is the token `<@userId|Name>` in the text
**and** the id in `mentions`; only a token whose id is listed is drawn as a chip, so pasted text
that looks like one stays text. Agents and older readers see `@Name`.

**The panel.** The chat button sits beside Share (badge: the unread count; `@` in the accent when one
of them mentions you); **C** shows and hides the panel from the board (never from a field or a
dialog). Docked on the right — the board keeps working beside it, its view resized — and its edge
drags from 260 to 520 px; under 960 px of window it floats over the board's right edge instead.
Shown or hidden is remembered per canvas per account in `canvas/chat.json` and survives a
relaunch; every tab on that canvas follows. Messages group by author (five minutes, one day), with
day lines, short relative times (full time on hover), your own on the right; it follows the newest
message unless you scrolled up, then a "N new messages" pill takes you down. Messages on screen
with the page visible are read; the read mark (message id and time) is kept per canvas per account
too. The first time a canvas is opened on this Mac its history counts as read — except an
unanswered mention of you, from which on it is new. Keys, copy and paste inside the panel stay in
the panel (the board's delete, nudge and shape clipboard never see them).

**The composer.** Enter sends, Shift+Enter is a new line, paste is plain text (a textarea). `@` opens
the people on this canvas — `GET /v1/canvases/:id/members`, asked for again when the picker opens
(at most every 15–20 s) and on `member_*`/`invite*` events, kept in `chat.json` so it is instant and
works offline — never yourself, never anyone else. Invites still waiting whose address has an
account are listed under **Invited** and can't be picked: they can be mentioned once they join.
Filtering is by name start, word start, email, then anywhere; ↑/↓, Enter or Tab picks, Esc closes,
the mouse works. A picked "@Name" is tinted in the field and bound to its id; on send each still
bound to a current member becomes a token (typed over, or a person who left: plain text).

**Mentions** (copper-cloud 0.6.0, `Cloud.Feature.mentions`). After a message that mentions someone
else, the page posts `{type:"mention", messageId, userIds, excerpt}` and Copper calls `POST
/v1/canvases/:id/mentions` (retried a few times while the cloud is away). Copper reads `GET
/v1/mentions?unread=1` when signed in, when the event stream comes (back) up and on every `canvas`
event of kind `mention`/`mention_read`. A new one, unless you are already looking at that canvas's
chat in the app in front:

- the **pill** at the window's foot, over the panels (stacked with the invite pill): "Ada mentioned
  you in “Team dinners”" with the excerpt, **Open** and × (Not now — the mention stays unread);
- an accent **dot on the Canvas door** and an `@` on the canvas's row in the card;
- the canvas's chat **button badge** (`setChat({mentioned:[messageId]})` keeps a mention unread in
  the page until it is seen, even before the read mark);
- a **macOS notification** when Copper isn't the app in front (`UNUserNotificationCenter`; macOS
  is asked once, when the first mention arrives — declined, never again). Clicking it is Open.

**Open** shows the canvas in front with its chat, scrolls to the message and flashes it, and marks
the mention read (`POST /v1/mentions/read {ids}`); the server tells your other Macs
(`mention_read`) and their pill, dot and badge go. Reading the message in the panel does the same.
On an older cloud chat works the same (it is in the document); a mention is a chip and a badge in
the canvas only — Copper never calls the API.

**Assignments ride the same path** (Checklists, *Assignees*). Putting someone on a checklist row
posts `{type:"mention", messageId:"assign.<shapeId>.<uuid>", userIds, excerpt:"<row> · <card
title>"}` — no cloud change: the mentions API takes any message id, and each assignment gets its own.
A mention whose id starts `assign.` is an assignment (`Mention.isAssignment`): the pill and the
notification say *assigned you*, a canvas whose chat you are watching still raises it (the card
may be elsewhere on the board), and **Open** leaves the chat as it was and calls `revealChat({id})`,
which the page answers by flying to the card (`controller.zoomTo`) and making your rows on it glow
once. The page never counts it in the chat's unread badge; it reads it (`chatRead` with its id)
once the card is on screen in a visible tab.

**Page ↔ host.** Page → host: `{type:"chat", open}` (remember it; other tabs follow),
`{type:"chatRead", id, at, mentionIds}` (the read mark; mentions of you among `mentionIds` are read
on the server), `{type:"chatMembers"}` (a fresh member list, please), `{type:"mention", messageId,
userIds, excerpt}`. Host → page (all guarded by `typeof … === 'function'`):
`copperCanvas.setChat({enabled, open, members:[{id,name,email,color}], invited:[{name,email}],
mentionsApi, lastReadId, lastReadAt, known?, mentioned})` (a patch, after `ready` and whenever
the entry, the members or the mentions change), `revealChat({id})`, `showChat(bool)`,
`chatSend({text, mentions:[id|name|email]}) → json`, `chatRead(limit) → [...]`, `chatState() → json`.
`copperCanvas.read` (so `canvas_read`) carries the last 50 messages under `chat`
(`{id, from, fromId, text, mentions:[{id,name}], at}`, text cut at 500 unless `full`).

**Tool.** `canvas_chat {id?, text, mentions?:[name|email]}` posts as the signed-in person: each
mentioned person must be on the canvas; one whose `@Name` isn't in the text gets it added in front.

```sh
./bench --world canvasE canvas chat state ID | read ID [N] | members ID       # page + host state; last N messages; the picker's people
./bench --world canvasE canvas chat send ID TEXT… [--mention WHO]…            # canvas_chat (WHO: one word — an email or a first name)
./bench --world canvasE canvas chat toggle ID | key ID                        # the button; the C key
./bench --world canvasE canvas chat focus ID | type ID TEXT | enter ID | escape ID | dom ID   # the composer as typed; what the panel shows
./bench --world canvasE canvas chat mentions | pill [open|dismiss] | frontmost on|off       # mentions, the pill, notices; act as if in front
docs/fixtures/canvas-chat-e2e.sh "<link code>"      # three probe worlds: picker, chips, live, relaunch, mentions (0.6.0) or the degrade (older)
docs/fixtures/checklist-e2e.sh "<link code>"        # checklist cards: one-click picks, same-millisecond ticks, old ⇄ new, legacy REST, cloud /read
docs/fixtures/checklist-assignees-e2e.sh "<link code>"   # assignees: agent and picker, ids, the "assigned you" pill on both Macs, Open → card, same-millisecond, cloud /read
```

## Testing it

Only in a probe world — never the windowed Copper on 4123:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk SEARCH_SIGN_IDENTITY=-; ./build.sh
defaults write com.officecommun.search.test.canvase bench -bool true     # the bench socket for this world
open -n -g --stderr /tmp/copper-canvas.log --env SEARCH_PROBE=canvasE --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT=4161 --env SEARCH_HEADLESS_SIZE=1440x1000 build/Copper.app
export SEARCH_PROBE=canvasE SEARCH_MCP_PORT=4161
C=build/Copper.app/Contents/Resources/bin/copper
$C health; $C tools | grep canvas_
$C call canvas_open '{"reason":"t","id":"personal","foreground":true}'
$C call canvas_apply '{"reason":"t","ops":[{"op":"add","shape":{"type":"sticky","text":"hello"}}]}'
$C call canvas_read '{"reason":"t"}'
$C shot /tmp/canvas.png
./bench --world canvasE canvas hosts      # each open canvas: ready, online, roomId, room, synced, status{mode,pending}, clients, collaborators, store
./bench --world canvasE canvas list | open ID | read [ID] | apply JSON | create NAME
./bench --world canvasE canvas invites | accept INVITE | decline INVITE      # INVITE: id or canvas name; invites also says the pill's
./bench --world canvasE canvas pill [dismiss|open]                          # the invite pill: what it shows; its × (Not now) and Open
./bench --world canvasE canvas stale accept|decline INVITE_ID CANVAS_ID      # test worlds: answer an invite by id the pill's way, even one no longer listed
./bench --world canvasE canvas pending ID                                   # the invites waiting on canvas ID, as its members see them
./bench --world canvasE canvas remind ID EMAIL | withdraw ID EMAIL          # invite again (a reminder on 0.5.0) / take an invite back
./bench --world canvasE canvas ui share resend EMAIL | withdraw EMAIL       # the Share sheet's Resend and × (after ui mode share ID)
./bench --world canvasE canvas rename ID -> NAME | delete ID | leave ID | members ID
./bench --world canvasE canvas ui mode new | picture /tmp/card.png [dark]  # the card, drawn off screen
./bench --world canvasE canvas new | tabs [ID] | menu [press] | flush ID    # ⌘K's New Canvas; every canvas's tabs (window, space, section, row, asleep, lean, mark, pill)
./bench --world canvasE canvas click X Y [N] | draw X,Y X,Y …               # real mouse input on the board in front, page CSS px
./bench --world canvasE canvas scroll DX DY [STEPS] [--zoom] [--app] | scroll stats   # a trackpad gesture (CGEvent, phased, 8 ms apart)
./bench --world canvasE canvas perf start | stop | lean                     # rAF frame times + wheel lag; what the tab was spared
./bench --world canvasE canvas ask-rename ID | ask-delete ID | answer rename NAME|delete|leave|cancel | sheet
./bench --world canvasE canvas rowmenu ID /tmp/menu.png | picture /tmp/window.png   # the row's menu; the window with its popover/sheet
./bench --world canvasE canvas import [status|run]                          # the easel migration
./bench --world canvasE canvas link [ID]                                    # make/reuse the invite link for ID (default: the front canvas): {link, webLink}
./bench --world canvasE canvas join LINK                                    # open an invite link the way clicking it would
./bench --world canvasE canvas presence [ID]                                # copperCanvas.presence() for ID right now: who's in the room, with cursors
./bench --world canvasE canvas parsetest                                    # self-test of the join-link parser (pure, no network, no window)
```

`canvas scroll` makes each event with CGEvent and gives it the board's window, so it is what a
trackpad's is to AppKit and WebKit; `--app` sends it through `NSApp.sendEvent` so the app's
monitors (the space swipe) see it first. Headless, the row's sheets are held open for `canvas
answer` instead of being declined (every other alert is), and `canvas picture` draws a held sheet
where it would hang; `canvas rowmenu` reads the real menu, puts it away at once, and draws its items
over the row (a parked window's menu would otherwise open on somebody else's screen).

Don't open the card's popover in a headless probe (`canvas ui open`): AppKit can loop on an
off-screen popover's constraints and abort the run — draw it with `ui picture` instead.

Two Coppers sharing a canvas, against a local copper-cloud with `tls.mode = "off"` (Cloud accepts
`http://` for a loopback host): run two probe worlds (`SEARCH_PROBE=canvasE` / `canvasF`, MCP ports
4161 / 4162), sign each in, `canvas_create` + `canvas_invite` on one, `bench canvas accept NAME` on
the other, then `canvas_apply` on either and `canvas_read` on the other.

`docs/fixtures/canvas-fixture.html` is a stand-in page with the same API over a plain map
(updates are base64 JSON) — copy it over `Resources/canvas.html` to exercise the host without the
real bundle.
