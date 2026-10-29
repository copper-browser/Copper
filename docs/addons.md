# Addons — web apps your Copper Cloud puts in a slot

*A Copper Cloud admin uploads an addon, a small web app in a bundle, and turns it on for
everyone or for some people. Copper downloads it, checks it, offers it beside its own update,
and once you install it the addon takes its **slot**. Today there is one slot, the **Agent
sidebar** that ⌘E opens. The addon runs in a web view of its own and reaches Copper only
through `window.copper`. It never sees your browsing, your cookies or Copper's keys.
Implementation: `Sources/Search/Fork/Addons/`. The cross-platform rules (manifest, bundle,
bridge, `state.json`) are shared with copper-linux and copper-windows, and these pages hold
the Mac's side of them.*

## Using it

- **When one arrives.** Copper asks your cloud for addons:
  - at launch (once the cloud link is ready),
  - whenever you link, unlink, sign in or sign out,
  - every six hours,
  - with every update check (Settings › About › Updates › Check now included),
  - and when the cloud says something changed.

  A new addon, or a new version, is downloaded and verified. Copper then offers it in the same
  places as its own update:
  - **Install <name>** in the update pill at the foot of the sidebar (or in the toolbar when the
    sidebar is folded), under Copper's own update, which keeps first place;
  - a card on **Settings › About › Updates**;
  - an **Install <name> <version> for the Agent sidebar** row in ⌘K.

  Click it and the addon is in place at once, with no relaunch. An update to an addon you
  already have says **Update <name>**. Right-clicking the pill gives **Remind Me Later**, which
  hides it until the next launch or the next version.
- **⌘E** opens the addon in place of the agent pane, at the pane's width
  (`agent.paneWidth`, 340–620 pt, dragged from its leading edge as the pane is). Closing it
  with ⌘E only hides it. The page keeps running, so a conversation in it is still there next
  time. If the page can't be shown (it failed to load, or its process stopped three times in a
  minute), ⌘E shows the agent pane instead, and Settings › Extensions › Addons says why.
- **Settings › Extensions › Addons** lists:
  - what is installed (name, version, slot, where it came from) and what waits to be
    installed;
  - **Use in Agent sidebar** for each addon. Off shows the agent pane there instead; the addon
    stays installed and gets no update offers while it is off;
  - **Remove**, which removes it from this Mac until your cloud next changes what you are
    assigned;
  - **Check for addon updates**.

  With no cloud linked, the page says addons come from Copper Cloud and offers to open
  Settings › Cloud.
- **Changes from the cloud.** When an admin removes or unassigns an addon, or turns it off,
  it goes from Copper at the next check and the slot shows the agent pane again. Changed
  settings apply at once, and the addon hears a `settings` event. Signing out leaves installed
  addons where they are. Linking a different cloud or account starts over.

## What an addon may do

An addon is files: `manifest.json`, an `.html` entry, and whatever scripts, styles and images it
needs. The manifest (`copper-addon/1`) names its slot and lists what it asks for. Copper holds it
to exactly that:

- **`permissions.hosts`.** The only hosts `copper.fetch` and `copper.oauth.authorize` reach.
  Each entry is `host`, `*.host` or either with `:port`. Only https is allowed, except plain
  http to `127.0.0.1` / `localhost`.
- **`permissions.capabilities`.** Any of `identity`, `storage`, `fetch`, `oauth`, `open-url`,
  `page` and `agent`. A method whose capability is missing answers `denied`.

The page itself is fenced in:

- **Data.** It has its own website-data store, shared by every addon and kept apart from every
  browsing profile. No cookie, sign-in or storage crosses either way.
- **Files.** Its files come only from its own bundle, at `copper-addon://<id>/<path>`. `/` is the
  entry, and anything else is a 404.
- **Network.** Every HTML file gets a Content-Security-Policy, as a `<meta>` first in `<head>`
  and as a response header. It allows scripts, styles, fonts and images from the bundle,
  images from https, and nothing else: `connect-src 'none'`, so `fetch`/XHR/WebSocket from the
  page are blocked, and the way out is `copper.fetch`.
- **Navigation.** It never leaves `copper-addon://<id>/`. A link to a web page that you click
  opens in a new tab. `window.open` is refused; use `copper.openUrl` or
  `copper.oauth.authorize`.
- **Messages.** Copper takes them only from the slot's own web view, its main frame, at the
  addon's origin.
- **Dialogs.** `alert` is logged and `confirm` answers false. A sidebar never puts up a modal.
- **Inspect Element.** It is available only in test worlds and dev builds, or with Developer
  mode on (`defaults write com.collinrijock.copper addons.developer -bool true`).

## `window.copper` (bridge v1)

`bridge.js` defines it at document start, before any of the addon's scripts. It is the same
file, byte for byte, on every platform: the canonical copy is copper-linux
`crates/copper-core/src/addons/bridge.js`, and the Mac's copy is
`Sources/Search/Fork/Addons/Resources/bridge.js` (a test checks its SHA-256). Every method
returns a Promise. A refusal rejects with an `Error` carrying `code`:

| code | meaning |
|---|---|
| `denied` | a capability or host the manifest doesn't list |
| `bad_request` | wrong or missing arguments, or an unknown method |
| `not_signed_in` | needs a cloud account |
| `cancelled` | the person closed it (OAuth window), or the page was replaced |
| `timeout` | took longer than allowed |
| `network` | no connection, or the answer was too big |
| `unavailable` | this platform doesn't have it, or the window went away |
| `internal` | Copper's fault |

| Method | Needs | On the Mac |
|---|---|---|
| `info()` | — | `{bridge: 1, platform: "mac", appVersion, slot, addon: {id, version}, capabilities, theme: {dark}}`. `capabilities` is what the manifest asks for, since the Mac has them all |
| `identity()` | identity | `{email, name, userId, cloud}` for the signed-in cloud account, or `null` |
| `settings()` | — | the settings the cloud resolved, which start as the manifest's `default`s |
| `storage.get/set/remove/keys` | storage | JSON values in `addons/data/<id>/storage.json` (0600), shared by every window, at most 1 MB per addon, keys 1–128 characters |
| `fetch(url, {method, headers, body, timeoutMs})` | fetch | `{status, headers, body}`, with header names lowercased and the body as text. Sent from Copper with no cookies, no cached credentials and no shared cache. `Cookie`, `Host` and the other transport headers are dropped. Body ≤ 2 MB, answer ≤ 8 MB, timeout 30 s by default and 120 s at most. Redirects are followed only to listed hosts; any other redirect comes back as the 3xx itself |
| `oauth.authorize({url, redirectPrefix, timeoutMs})` | oauth | Opens a 520×680 sign-in window on your browsing profile (the space in front's), so single sign-on is already there. It watches every navigation and server redirect, and the first whose URL starts with `redirectPrefix` is stopped. The window closes and the result is `{url}`. `redirectPrefix` must be `http://127.0.0.1:<port>/…`, `http://localhost:<port>/…` or https on a listed host; nothing listens on that port. Closing the window gives `cancelled`; the default timeout is 5 minutes |
| `openUrl(url)` | open-url | opens an http(s) address in a new tab in front |
| `page.current()` | page | `{url, title}` of the tab in front, or `null` (also for a private tab) |
| `ui.close()` | — | hides the slot, as ⌘E does |
| `agent.state()` | agent | the ⌘E agent's one conversation: `{available: true, busy, models: [{id, name, ready, detail}], model, items}` |
| `agent.setModel(id)` | agent | `haiku`, `sonnet` or `opus` (the ids `agent.state()` lists); the same as Settings › Intelligence |
| `agent.send(text)` | agent | asks the agent, as typing in the pane would. `bad_request` while it is still answering |
| `agent.stop()` / `agent.clear()` | agent | Stop (nothing when the agent is idle) / New chat |

Agent items are `{id, role, text, at, busy?, detail?}`:

| role | what it is |
|---|---|
| `user` | the question |
| `assistant` | the answer |
| `activity` | words on the way to a tool call, a tool call (its title, with what it found as `detail`), or a note |
| `error` | a note that something failed |
| `drive` | Jev at work in a tab |

**Events.** `copper.on(name, fn)` returns an unsubscribe function.

| event | payload | when |
|---|---|---|
| `visibility` | `{visible}` | the slot is shown or hidden (⌘E) |
| `theme` | `{dark}` | the window's appearance changes |
| `settings` | the new settings object | the cloud changed this addon's settings |
| `agent` | as `agent.state()` | the conversation changes, at most ten a second (needs agent) |
| `page` | `{url, title}` or `null` | the tab in front, or its address or title, changes (needs page) |

**Secure context.** `copper-addon:` is a custom scheme. Check `window.isSecureContext` (the
self-test reports it) before relying on `crypto.subtle`. For PKCE without it, compute the
SHA-256 in plain JavaScript.

## Writing and testing an addon

- **Development folder.** Point `COPPER_ADDONS_DEV_DIR` at an unpacked addon (a folder with
  `manifest.json`) and start a test-world Copper (`SEARCH_PROBE=1`, or a dev build). The folder
  takes the slot ahead of anything installed and is read live, so a reload shows edits. The
  same works at run time with `./bench agent addons dev /absolute/folder` (and `dev off`).
  Settings › Extensions › Addons shows the folder with a Reload button.
- **Packing.** `docs/fixtures/addons/pack.py FOLDER OUT.json` writes the served bundle format (one
  JSON document with every file base64'd, sorted by path) and prints its SHA-256. Copper Cloud
  builds the same thing from an uploaded `.copperaddon` zip.
- **Fixture.** `docs/fixtures/addons/selftest/` is an addon that calls every method and logs
  every event. It is a page to look at, and what the bench self-test installs.

### Bench (`./bench agent addons …`)

Paths are passed as written, so use absolute ones. Anything that installs or stands in for the
cloud runs only in a test world.

| op | does |
|---|---|
| `status` | `state.json`, what every window's slot shows (`loaded`, `visible`, `failed`, `url`), the development folder, and the last few log lines |
| `check` | asks the cloud (or the fake) now |
| `fake RESOLVED.json BUNDLES/` / `fake off` | stands in for the cloud: the file is read as `GET /v1/addons` on every check, and `BUNDLES/<sha256>.json` as each bundle. Everything after (plan, verify, stage, pill, Install) is the real path. `pack.py FOLDER OUTDIR --fake` writes both |
| `stage BUNDLE.json` | stages a served bundle as if downloaded |
| `install [SLOT]` | installs what is staged |
| `enable ID on\|off`, `remove ID` | the Settings switches |
| `dev FOLDER\|off` | the development folder |
| `open`, `close` | the Agent sidebar (⌘E) |
| `reload` | the front window's slot page, loaded again |
| `emit EVENT [JSON]` | sends an event to the front slot page |
| `eval JS` | runs an async function body in the slot page; `result` returns its value |
| `shot PNG` | pictures the front window (`PNG`) and its slot page (`….slot.png`); the paths come from `result` |
| `selftest BUNDLE.json [PNG]` | stages, installs, opens, calls every method through the page's own `window.copper`, pictures the window (`PNG`) and the slot (`….slot.png`), then checks `ui.close()`. The answer comes from `result` |
| `result` | what the last `selftest` or `eval` returned |

Keep the bench's files on the internal disk (`/tmp` is fine). A dev build that reads a file on an
external volume waits on macOS's removable-volume permission prompt, and its main thread waits
with it.

A full pass by hand:

```sh
python3 docs/fixtures/addons/pack.py docs/fixtures/addons/selftest /tmp/addon-fake --fake
SEARCH_PROBE=1 ./bench start
./bench agent addons fake /tmp/addon-fake/resolved.json /tmp/addon-fake
./bench agent addons status          # pending: com.example.selftest, the pill shows
./bench agent addons install
./bench agent addons open
./bench agent addons selftest "$(ls /tmp/addon-fake/*.json | grep -v resolved)" /tmp/addon.png
./bench agent addons result
```

## On disk

Under Copper's data folder (`~/Library/Application Support/Copper/`, or the test world's):

```
addons/
  state.json                 schema, revision, installed, pending, disabled, last_check (+ owner)
  bundles/<id>/<sha256>/…    unpacked files, never changed once written
  staging/<sha256>.json      downloaded, verified, waiting for Install
  data/<id>/storage.json     copper.storage (0600, folder 0700)
```

- **Writes.** Every write is atomic (temp file and rename). A bundle is unpacked into a hidden
  sibling folder and renamed into place.
- **Cleanup.** At launch, bundle folders and staged files that `state.json` no longer
  mentions are removed. So the bundle an install replaced stays until the next launch.
- **A damaged `state.json`** is set aside as `state.unreadable-<time>.json` and Copper starts
  with no addons. The next check installs what the cloud assigns again.
- **The account.** `owner` remembers which cloud and account the state belongs to, so linking
  another one fetches afresh.

## How it fits together

- **`AddonSync`** (`AddonSync.swift`) follows `CloudIntelligence`'s lifecycle. `MCP.start`
  starts it, it listens to `Cloud.didChange` and the `addons` event, it is called from
  `Updates.check`, and it keeps its own six-hour timer.
  - **Fetch.** It reads `GET /v1/addons`. A 404 means none. Offline or a 5xx keeps everything
    as it is.
  - **Plan.** `AddonPlan.make` decides per slot: remove, settings only, stage, or drop the
    pending entry.
  - **Stage.** It downloads each new bundle and verifies it (`AddonBundle.verify`).
  - **Order of checks**, the same as copper-linux: size → SHA-256 → format → manifest valid and
    matching the cloud's entry → each file's path and SHA-256 → no duplicate or clashing paths
    → the entry present.
  - **Revision.** The cloud's revision is remembered only once everything staged, so a failed
    download is tried again at the next check. (`Cloud.request` sends no custom headers, so the
    revision is compared on the client rather than sent as `If-None-Match`.)
- **`AddonSlotHost`** (`AddonHost.swift`) is one per window and slot. It owns the persistent
  `WKWebView`, the `copper-addon` scheme handler (`AddonFiles`), the navigation policy
  (`AddonNavigation`), the message handler (behind a weak proxy) and the events.
  `AddonSlotHost.sync()` makes every window follow `AddonSync`.
- **`AddonBridge`** (`AddonBridge.swift`) holds the methods, `AddonStorage`, `AddonFetch` and
  `AddonOAuth`.
- **`AgentSlot`** (`AddonUI.swift`) is what `Split.swift` puts where `AgentPane` was.
  `AddonPillSlot` sits beside the update pill. `AddonsPage`, `AddonUpdatesSection` and
  `AddonCommands` are the rest of the UI.
- **Hooks** in other files are single lines marked `// Fork (addons)`: `Split.swift`,
  `UpdatePill.swift`, `Updates.swift`, `SettingsFork.swift`, `CommandBar.swift`,
  `SettingsIndex.swift`, `MCP.swift`, and the upstream `Settings.swift` and `Package.swift`
  (PATCHES.md `addons-settings`, `addons-resource`).
- **Tests** are in `Tests/SearchTests/AddonsTests.swift`.
