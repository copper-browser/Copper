# Trails (a preview, in Settings › Tabs › Previews)

Arc made tabs spatial. Trails makes them intentional: you stop managing
tabs, and the column keeps the story of what you were doing.

A **trail** is one line of intent. It starts where you typed something — a
search, an address, a link that came in from another app — and grows as you
open pages from it. A page opened from a page belongs to that page's trail,
under it. Today's forty rows become a handful of trails.

Trails is a **flight**: built in, off by default, and switched on per Mac in
**Settings › Tabs › Previews › Trails — organise tabs by what you were doing
(preview)**. Turned off, nothing of it runs and the column is exactly what it
was; turned on or off, the column redraws at once, no restart.

## What changes in the column

Only the Today block — the loose, unsaved rows under **New Tab**. The lights,
the address, the favourites, the space's name, the rows you keep and their
folders, the hairline and New Tab itself stay exactly as they are, and so do
pins, Saved, folders, canvases and the space switcher.

- **A trail of one page** is that page's row, as before.
- **The trail you are on** opens out: a header with its name, then its pages
  as a lineage — each page under the page it was opened from, joined by a
  thin thread, three levels at most (deeper pages are drawn at the third).
  The page you are on wears the usual pill.
- **Every other trail** is one row: its name, a small overlapping stack of
  its sites' marks, and how many pages it has. Click it to go to the page
  you used last on it; the chevron (where the mark is, under the pointer)
  opens it in place without going anywhere. Folded while it holds the page
  you are on, the row wears the pill so you can always see where you are.
- **Its name** is the search it began with — `q=`, `query=`, `p=`, `wd=`,
  `text=`, `search_query=` on Google, Bing, DuckDuckGo, Kagi, Brave, Ecosia,
  Startpage, Yahoo, Baidu, Yandex, Perplexity, and the search pages of other
  sites — shown with a magnifying glass; otherwise the title of its first
  page, with a path mark. Double-click a trail's row, or **Rename Trail…** on
  its menu, to name it yourself; the name is kept.

### What starts a trail, what joins one

| you… | the page… |
|---|---|
| type into the address bar, ⌘L, ⌘T or ⌘K | starts a new trail (a tab that had other pages on its trail leaves it; the pages it opened stay, under the page it came from) |
| ⌘-click, middle-click, `target=_blank`, `window.open` | joins its opener's trail, under the opener |
| open a link from another app | starts a new trail |
| follow a link in the same tab | stays where it is |
| drag a row onto another trail | moves to that trail, at its top level |
| drag a row into the space between trails | becomes a trail of its own |

### Closing a trail

Hover a folded trail and its count turns into ✕; or **Close Trail** on its
menu; or **View › Close Trail** (⌘⇧W) for the trail you are on. Every page
closes the ordinary way, so each lands in **Reopen Closed Tab** — and ⌘⇧T
puts it back **on its trail**: in its old place, under its old parent, with
the trail's name, until the whole trail is back. Closing the trail you are
on lands you on the next trail down.

## Tide

Trails left alone longer than the **Tide** setting (Settings › Tabs › Previews: 6h,
**12h**, 24h, Never) drift under a quiet **Earlier** divider, grouped
*Today*, *Yesterday*, *This Week* and *Older*, as single slim rows at less
emphasis. When a trail first drifts there its pages may sleep — through
Copper's ordinary tab sleep, with every reason a page has to stay awake
still heard (sound, a call, a download, unsaved typing, any window's stage,
the split view), and only with **Settings › Tabs › Sleep tabs you aren't
using** on. Nothing is
closed or deleted by Tide. Pick one and it is back at the top.

A trail holding any window's front page, or a pane of the split view, never
drifts. Tide is separate from **Archive Today after** (Settings › Tabs),
which still closes untouched Today rows on its own clock unless it is set
to Never.

## Glance

Rest the pointer on a folded trail for 350 ms and its pages come out beside
the column as a small filmstrip: a picture of each page you have looked at
this session (taken as you leave it, from the view that already exists),
otherwise its mark, host and title. Click a card to go to that page; move
away, press Esc or click elsewhere to put it back. Glance never builds or
loads a page to draw a card. Pictures live in memory only, the last 48.

## Ask about a trail, put it on the canvas

On a trail's menu (right-click the row, or the header of the open one):

- **Ask About This Trail** opens the ⌘E agent pane with the trail in the
  composer — its pages in order, indented by lineage, with their addresses —
  and a question to start from. Nothing is sent until you send it. Also in
  the View menu while Trails is on.
- **Send Trail to Canvas** puts the trail on your **Personal** canvas as a
  frame named after it, a link card per page laid out by depth, and an arrow
  from each page to the pages opened from it — to the right of whatever is
  already there — and shows it. It goes through the same `canvas_apply` the
  agents use, attributed to *Trails*.

## Where it is kept

`trails.json`, beside `session.json` in Copper's folder (a probe world's own
folder in a test run), written a moment after anything changes — on one
serial queue, as `windows.json` is — and straight away at quit.
`session.json` is never touched: its format is unchanged and older builds
read it as before.

```json
{
  "version": 1,
  "trails": [{ "id": "…", "founder": "…", "title": "my name", "query": "swift concurrency",
               "settled": true, "caption": "…", "created": 1791047400, "used": 1791048400, "rank": 1791047400 }],
  "pages":  [{ "key": "…", "space": "…", "url": "https://…", "ordinal": 0,
               "trail": "…", "parent": "…", "opened": 1791047400, "used": 1791048400 }]
}
```

A tab's id is new every launch, so a page is found again by its **space,
address and ordinal** (which of that space's rows with the same address it
is) — what the session restores it from — falling back to address and
ordinal in any space for a page moved between spaces. `parent` and `founder`
refer to `key`, the id the page had when the file was written.

Trails records lineage only while it is on. Rows from before (or from a
session where it was off) each start as a trail of their own, except a page
whose opener is still open — Copper already remembers the opener for the
life of a tab — which joins its opener's trail. A file that can't be read is
set aside (`trails.unreadable-<time>.json`) and Trails starts afresh.

## Windows, spaces, split view, canvases

Each window draws the trails of its own space from its own rows (always
through the window's browser, never the front window's space). Lineage is
kept for every space at once, so switching spaces or moving a page to
another window keeps its place. Pins, Saved rows, folders and canvas tabs
never join a trail. The split view's panes count as on stage.

## Testing it

```
./bench --world W flight trails on        # or off; `flight` lists, `flight tide 6h|12h|24h|never`
./bench --world W trails                  # every trail: title, place, age, pages by depth
./bench --world W trails open URL [FROM]  # a page, opened from tab FROM as ⌘-click would
./bench --world W trails type ID WORDS    # an address or search typed into a tab
./bench --world W trails backdate N 13    # make trail N's last use 13 hours ago (Tide)
./bench --world W trails glance N|off     # hold a Glance open for `window PATH`
./bench --world W trails toggle|close|ask|canvas N
./bench --world W trails rename N TEXT
./bench --world W trails move ID N|new
./bench --world W trails file             # trails.json as just written
./bench --world W trails menu             # what ⌘W / ⌘⇧W are bound to
```

## Limits

- A preview: lineage is per Mac and never synced (not part of Copper Cloud).
- The tree draws three levels; deeper pages sit at the third.
- Trails are named by their search or first page; there is no automatic
  (AI) naming.
- Dragging rows between trails is by mouse only; there is no keyboard
  equivalent yet. Reordering pages inside a trail isn't offered — their order
  is the order they were opened in.
- Glance pictures are taken as you leave a page, so a page opened behind and
  never looked at shows its card.
- Typing the same address again into a tab still starts a new trail.
