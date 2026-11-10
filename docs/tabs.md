# Tabs

`⌃Tab` and `⌃⇧Tab` walk the row (so do `⌘⇧]` and `⌘⇧[` in the **Tabs** menu).
In **Settings › Tabs**, **⌃Tab switches to** chooses whether Control-Tab follows
the next tab in the row or the tabs used most recently. Plain `Tab` never
switches tabs: on a page it is the page's (moving between fields, a site's own
Tab-to-accept, code editors), and in the address field (`⌘L`) it takes the
completion on offer — the text goes in the field with the caret after it, and
nothing opens until Return.

In **Most recent tab** mode, `⌃Tab` walks older tabs and `⌃⇧Tab` walks back
toward newer ones. The list belongs to the current space. It is frozen while
Control is held and committed when Control is released, so two quick presses
flip between the two latest tabs. Holding Control for about 180 ms reveals the
same walk as a small strip over the page; a quick press does not flash it.

Tab renaming keeps its existing Tab behaviour.
Closing a tab removes it from the list, and changing spaces rebuilds the list
from that space's row.

## The ⌘T and ⌘K card

The card's rows come in sections, always in this order: **Open Tabs**,
**History**, then **Bookmarks**, **Canvases** and **Commands** when anything
matches, and **Search** (the Google search for what you typed, then Google's
completions) last. A section only shows while it has rows, under a quiet
heading; within one, rows keep their ranking. With nothing typed, ⌘T shows
**Recent Tabs** and **Recently Closed**.

The first row is highlighted as the card opens and on every keystroke, so
Return takes the best open tab or page you have been to, and searches only
when nothing else answers. An address typed in full — `github.com`,
`localhost:3000`, an `https://` link — leads the card under no heading and
opens on Return. In ⌘T, a query starting with `/` lists commands only.

`Tab` and `⇧Tab` move the highlight to the first row of the next or previous
section, round the end; `↑` and `↓` still walk row by row across sections. The
keyboard stays in the field. `→` at the end of what you typed puts the
highlighted row's address (or a search's words) into the field to edit, which
is what Tab did here before. `./bench newtab TEXT --keys "⇥⇧⇥↓"` and
`./bench summon TEXT --keys …` press these keys in a probe world's card
(`Fork/CardSections.swift`).

## Links from other apps

A link clicked in Slack, Mail, Forca or a terminal's `open https://…` opens in a new tab
in front of you (or in the blank tab you are on): the browser window at the top of the
stack, skipping Settings and other panels, then one in the Dock, then the first window
brought back if every window is closed. LaunchServices may hand the link to an agent's
headless or test-world Copper instead of yours; that probe passes it on to the main
Copper by pid (docs/headless.md). `.html`, `.webloc` and `.url` files opened with
Copper open their page (`Fork/LinkRelay.swift`).

## Pinned tabs never unload

A pinned tab (a favourite, in the grid every space shows) keeps its page loaded from the
moment it is pinned, or from launch, until it is unpinned. There is no setting for it
(`Fork/PinsAwake.swift`).

- **Nothing puts one to sleep.** The idle sweep and memory pressure pass over pins
  (`Browser.awake(because:)` says "pinned"), and `Tab.sleep(picture:)` and `Tab.rest()`
  refuse one whoever calls them — an extension's `chrome.tabs.discard` included. Only
  closing it for good (after Unpin, a canvas deleted, a pin another Mac removed) lets its
  page go.
- **⌘W on a pin steps away from it.** File › Close Tab, the wheel button, Close Tab in ⌘K,
  an agent's or an extension's close: you land on the tab you were on before (an
  ordinary one, never another pin; a blank tab if there is none), and the page is still
  there, loaded, when you come back. Close Other Tabs leaves the pins as they are. Up to
  November 2026, ⌘W put a pin down and let its page go.
- **A launch loads them in the background.** The pins a session brings back, the one on
  screen aside, are loaded once the first page has drawn, one at a time, out of sight (in
  the Room, as Fork/SpaceWarm.swift loads each space's page) — before the other spaces'
  pages, and on battery saver or in a headless run too. A tab pinned while asleep (a
  Saved row put down, a tab brought back asleep) or a pin another Mac sends is loaded the
  same way a moment later.
- **A page whose process went away is loaded again at once.** macOS ends background web
  processes under memory pressure; a pin's page is reloaded in the background as soon as
  WebKit says so, and the trail says `pin-reload host=… n=…` (docs/crashes.md). A page
  that takes its process down as it loads gets three such reloads in ten minutes
  (`PinReloads`); after that the trail says `pin-reload-stop` and the pin waits to be
  reloaded when you come back to it, as any other tab does.

Unpinned, a tab is an ordinary tab again and sleeps by the ordinary rules.

`./bench pins` lists every pin — loaded or not, its web process, its reloads in the last
ten minutes; in a test world `./bench pins kill ID` ends a tab's web process as macOS
does, and `pins close ID` / `pins others ID` are ⌘W and Close Other Tabs.
`docs/fixtures/pins-awake-e2e.py` runs all of the above in a fresh headless world.

## Coming back to a sleeping tab

A tab that went to sleep shows its last picture the instant it is picked — drawn at
the size it was taken, from the page's top-left corner, on the page's own background
colour, inside the stage as it is now (the picture never sizes the stage, so the
sidebar never moves) — and the picture comes down once the rebuilt page has painted.
The rebuilt page loads once its view is in the window (with one bounded fallback for
an offscreen view); putting the tab back to sleep or sending it elsewhere cancels that
restore's delayed work.
