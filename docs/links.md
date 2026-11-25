# Where links open: Little Copper, Peek, Air Traffic Control

## Little Copper (⌥⌘N)

A small window with one page: no sidebar, no row of tabs, a slim bar with
back, the address (⌘L or a click to type another) and **Open in Copper**
(⌘O or ⌘↩), which moves the page into the browser window in front as its
active tab — the same web view, nothing loads again — in the space it was
opened for. ⌘W closes it, ⌘R reloads, ⌘[ ⌘] go back and forward, ⇧⌘C
copies the address. The page is a tab in no window's row: it is not in the
session, never sleeps, and closes with its window. Also ⌘K › New Little
Copper Window. Code: `Fork/Little.swift`.

## Peek (⇧-click)

⇧-click a link and it opens in a card over the page you are on (a child
window of the browser window). ⎋, ⌘W or a click outside the card put it
away; ⌘↩ keeps it as a tab beside the page; ⌥⌘↩ opens it in a split. With
Settings › General › Where links open › Peek at links from pins on, a
plain click in a pinned tab on a link to another site (`Fork.brand` differs)
peeks too, so the pin stays on its own site. Code: `Fork/Peek.swift`; the
hook is one line in `Browser.decidePolicyFor`.

## Air Traffic Control

Rules for links from other apps, kept in `air-traffic.json` in the world's
folder and edited in Settings › General › Where links open:

- **From** an app (its bundle id) or any app. The sender is the Apple
  Event's sender process; a command-line `open` counts as the app it runs
  under (Terminal, iTerm…), the nearest ancestor with a bundle.
- **For** any site, a host (`github.com`, its subdomains and `www.` too), a
  path under a host (`github.com/copper-browser`), or a pattern with `*`
  over the host, or host and path once it has a slash (`*.google.com`,
  `*/pull/*`).
- **Open in** a space (or whichever is in front) and as a tab, a new window
  or Little Copper.

The first rule that fits wins; **Everything else** takes the rest, and left
as it comes (the space in front, a tab) it is what Copper always did.
**Try a link** says where a link from an app would go. Rules run in
`LinkRelay.land` and for the links that launched the app (`Links.hand`),
never for a click inside Copper. `AirTraffic.shared.adopt(_:)` adds rules
from elsewhere without doubling ones already kept: a move in from Arc
brings Arc's (`StorableLinkRouting.json`, `Fork/Flow/FlowArcExtras.swift`).
Arc's "contains" text becomes `*text*`, "matches" the plain address; a rule
for a space that didn't come over is left out, Little Arc is Little Copper,
and Arc's Everything else is taken only when it names a space and Copper's
is untouched.
Code: `Fork/AirTraffic.swift`, `Fork/AirTrafficSettings.swift`.

## Bench

    ./bench little [open [URL]|copper [N]|close [N]|shot N PATH]
    ./bench peek [open URL|click SELECTOR|key ⎋|⌘↩|⌥⌘↩|tab|split|close|pins on|off]
    ./bench atc [add site=S [app=BUNDLE] [space=N] [open=tab|window|little]|else …|clear|try URL [APP]|route URL [APP]|last|from PID]

End to end: `docs/fixtures/air-traffic-e2e.sh` (a headless probe world
that keeps links for itself, `open -a` the built app, a local page server).
