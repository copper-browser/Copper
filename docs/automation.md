# AppleScript, Handoff and the Task Manager

## AppleScript

Copper speaks Chrome's and Arc's AppleScript words, so Raycast and Alfred
scripts written for them work here. The dictionary is
`Sources/Search/Fork/Copper.sdef`, and the objects behind it are in
`Fork/Scripting.swift`. Script Editor › Open Dictionary shows the dictionary.

```applescript
tell application "Copper"
  get URL of active tab of front window
  get title of every tab of front window
  tell front window to make new tab with properties {URL:"https://example.com"}
  make new window with properties {URL:"https://example.com"}
  set active tab index of front window to 2
  tell tab 3 of front window to select
  set URL of active tab of front window to "https://example.org"
  close tab 3 of front window
  execute active tab of front window javascript "document.title"
end tell
```

- `window` is a browser window, front first. Settings, Little Copper and the
  rooms where Copper loads pages out of sight are not windows here. Its tabs
  are the row it shows, pins first.
- `execute … javascript` and setting a tab's URL to a `javascript:` address
  need **View › Allow JavaScript from Apple Events**. It is off by default, as
  in Safari and Chrome. Without it, any app this Mac lets send Copper events
  could read every page you are signed in to. The answer comes back as text, a
  number or a list. Anything else comes back as its JSON.
- A sleeping tab runs no JavaScript. Select it first.

## Handoff

The active tab of the window in front is this Mac's current browsing activity
(`Fork/PageHandoff.swift`). An iPhone or another Mac on the same Apple Account
offers to carry on with it. The activity follows the tab's address and title,
including a single-page site's address changes. Private tabs, blank tabs and
anything that isn't http or https are never offered. A page handed to this Mac
lands the way a link from another app does.

## Task Manager

**Window › Task Manager** (also in ⌘K) lists every tab with a page loaded, in
any window or space, heaviest first (`Fork/TaskManager.swift`). Each row shows
the memory its web process holds (the same footprint Sleep weighs) and the CPU
it used over the last 2 seconds. Tabs that share a process show the process's
numbers on each row. **Sleep** puts the chosen tabs to sleep by the idle
sweep's rules. A tab on screen, playing sound or holding something typed stays
awake and says why. **End Process** stops the page's process, as Chrome's
does. The tab on screen loads again at once. Others show their page went away
and reload when you go back.

## Testing

`docs/fixtures/automation-e2e.sh` runs all three in a headless probe world. The
scripts go through `/usr/bin/osascript` started by Copper (`./bench script run`).
An osascript started over ssh would wait on a consent prompt that nobody can see.
