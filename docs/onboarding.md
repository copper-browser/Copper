# Getting started with Copper

A guide for someone joining a team that uses Copper: install it, move in from
Arc, Chrome or Safari, link it to your team's Copper Cloud, and use the agent. Every
menu name and shortcut below is the one in the app. Team-specific details —
the instance address, who hands out link codes — come from your Copper Cloud
administrator, not from this page.

## What Copper is

Copper is a small, fast browser for the Mac. It runs on WebKit, the engine
already inside macOS, so it is about 11 MB and opens instantly. You get tabs
across the top or down the side, spaces, built-in ad blocking and reading
mode, passwords in your keychain (or Bitwarden), and an agent pane beside the
page that can read and act in your tabs. Linked to a Copper Cloud instance
your team runs, your spaces, bookmarks, history and settings follow you
between Macs, and shared canvases are live. Nothing leaves the Mac until you
turn it on.

Requirements: macOS 14 or later, on Apple Silicon or Intel.

## 1. Install

Pick one:

```sh
# Homebrew (also puts the `copper` command on your PATH)
brew install --cask copper-browser/copper/copper

# Or the installer from the latest GitHub release
curl -fsSL https://github.com/copper-browser/Copper/releases/latest/download/copper-install.sh | sh
```

Both put `Copper.app` in `/Applications`, clear the download quarantine flag
(Copper is signed with its own certificate, not notarized), link the `copper` command
and open the app. The installer keeps your tab session if Copper was already
installed. Downloading the zip by hand also works: move `Copper.app` to
`/Applications` and run `xattr -cr /Applications/Copper.app` once.

### First launch

Four short pages, each skippable:

1. Welcome.
2. **Bring things over.** If another browser is on the Mac, Copper offers its
   passwords, bookmarks and history (**Bring them in**). If you plan to move
   in from Arc, Chrome or Safari with Move in (step 2), you can skip this — Move in
   brings all of that and more.
3. **Two ways to hold it.** *Tab strip* (tabs across the top) or *Sidebar*.
   Change your mind any time with <kbd>⇧⌘S</kbd>.
4. **Links from other apps.** Make Copper the default browser if you want
   links from Mail, Slack and PDFs to open here.

### Updates are automatic

Copper checks its GitHub releases after launch and every six hours, downloads
a newer build in the background and verifies it (checksum, bundle identity,
code signature, and that it is signed with Copper's own certificate — the same
one every release has, which is why the permissions you give Copper survive
updates). Only then does a pill appear at the foot of the sidebar (or
beside the downloads button with tabs across the top): **Update Copper**, then
**Restart to Update**. The restart backs up your tabs, swaps the new Copper in
and relaunches in a few seconds. It never restarts without your click.
Settings › About › Updates has **Check now** and, if something fails, the reason and
**Open log**. Plain `brew upgrade` leaves Copper alone because it updates
itself; `brew upgrade --cask copper` still works if you want it.

If you installed Copper before version 1.0.20261007.42 (7 October 2026), the
first update to it or later asks for your permissions one last time: turn
Copper on again in System Settings › Privacy & Security › Full Disk Access and
Files & Folders, and click **Always Allow** if the keychain asks. Earlier
releases weren't signed with Copper's certificate, so macOS saw each update as
a new app. From then on the permissions stay ([releasing.md](releasing.md)).

## 2. Move in from Arc, Chrome or Safari (Flow)

Open Move in any of these ways:

- **View › Move in from Another Browser…** (<kbd>⌥⇧⌘I</kbd>)
- **Settings › General › Move in from another browser › Move in…** (Settings
  is <kbd>⌘,</kbd>)
- <kbd>⌘K</kbd>, then *Flow: move in from Chrome, Safari or Arc*

Pick the browser. Chrome, Safari and Arc are the main sources; other
Chromium-based browsers on this Mac appear in the same picker. Copper counts what it found,
then shows one switch per kind:

| Switch | What arrives |
|---|---|
| Tabs and windows (Arc: Tabs and spaces) | Open windows, Arc spaces, pinned tabs and tab groups, as Copper spaces whose tabs stay asleep until you visit them. A window with only new-tab pages makes no space. A name you already use gets the browser's name: ` (Arc)`, ` (Chrome)`. |
| Bookmarks | The whole tree, folders and all. |
| History | Every visited address from the profile (up to 20,000 places kept), so the address field completes from it. |
| Passwords | Saved sign-ins, into your macOS keychain. |
| Passkeys | Passkeys saved in the browser's own password manager. |
| Sign-ins | Cookies, so you stay signed in to sites. |
| Site data | What sites keep in the page: settings, drafts, workspaces. |
| Extensions | Chrome Web Store extensions, reinstalled in the background. |

Press **Bring it all over**. For passwords, passkeys and sign-ins, macOS asks
once to let Copper use the browser's saved passwords (*Chrome Safe Storage* /
*Arc Safe Storage*); say **Allow**. If you refuse, everything else still
moves. Move in only reads the other browser's files; it never changes them.

When it is done, the sheet lists each kind with what arrived, or why nothing
did, and stays up until you press **Done**, which takes you to the first space
it brought over. After a Chrome move that brought tabs or bookmarks, **Open the
Chrome guide** opens a short local canvas on where everything landed. Moving in
again adds only what is new: no repeated spaces, tabs or bookmarks. **Undo**
on the done screen takes back only what that move added. You can close the
sheet while it moves; the move goes on, and the next time you open Move in it
shows what came.

**Chrome shows "macOS needs your OK"?** macOS keeps Chrome's folder private
and never asks on its own. Press **Allow in System Settings…** on Chrome's
card: Privacy & Security › Files & Folders opens. Turn on Copper's switch for
Chrome and come back to Copper; the card unlocks by itself. Or press **Use an
export instead…** and drop the bookmarks file (Chrome: Bookmark manager ›
Export bookmarks) or passwords file (Chrome: Password Manager › Settings ›
Export passwords). A file needs no permission but brings no open tabs,
history or sign-ins. Delete an exported passwords file afterwards.

**Safari shows "macOS needs your OK"?** Safari's files are behind Full Disk
Access. Press **Allow Full Disk Access…** on Safari's card, turn on Copper in
Privacy & Security › Full Disk Access and come back (if the card still says
it is locked, quit and reopen Copper). Or press **Use an export instead…**:
in Safari, choose **File › Export Browsing Data to File…** and drop the zip on
the sheet. The export brings bookmarks, the Reading List, history and
passwords, but not open tabs; Full Disk Access brings open windows and tab
groups too, but passwords only ever come from the export. Payment cards and
Safari extensions stay in Safari. Delete the export afterwards.

Move in does not move Apple Passwords, iCloud tabs, passkeys stored in iCloud
Keychain, or a password manager's vault. For Apple Passwords, export a CSV
from the Passwords app (**File › Export All Passwords**) and use
**Settings › Passwords › Import…**; delete the CSV afterwards. Import checks the
file first and says exactly what it took, or what is wrong with the file.
**Settings › Passwords › Export…** writes every password Copper keeps to a CSV
after Touch ID; anyone with that file can read them, so delete it when you're
done.

## 3. Copper Cloud: link, create your account, sync

Copper Cloud is a server your team runs. Copper links to one instance at a
time, signs in to your account there, and syncs what you switch on.

### Your company signs in with Google?

If your admin set up single sign-on, they share a **/start** page (or a join
link, `copper-cloud://HOST:PORT/#sso=google&fp=…`). On the page, press
**Open in Copper** — Copper opens Settings › Cloud and your browser at Google's
account picker — and choose your work account. That's all: this Mac is
connected, signed in and syncing. (Pasting the join link into Settings › Cloud
and pressing **Continue with Google** does the same.) No link code, no
password. Details: [cloud.md › Single sign-on](cloud.md#single-sign-on-continue-with-google).
Otherwise, read on.

### Get a link code

Ask your Copper Cloud administrator for a **link code**. It looks like:

```text
copper-cloud://HOST:PORT/#k=<your access key>&fp=<certificate fingerprint>
```

Treat it like a password: it is your personal key to the instance. Do not
paste it in chat channels or commit it anywhere.

How accounts are made depends on the instance's access mode:

- **Directory mode** (the default for new instances): the admin mints a
  personal access key for you in the instance's admin portal (*Access keys ›
  New key*). Its link code lets you create one account. The key may be tied to
  your email — sign up with that address. The admin can revoke it at any time.
- **Open mode:** one shared link code for everyone; you create your own
  account with it (unless the admin has closed sign-up).
- Either way, an admin can also create the account for you and tell you the
  email and a starting password; then you **Sign in** instead of creating one.

### Connect and sign in

Open **Settings › Cloud** (or <kbd>⌘K</kbd> › *Copper Cloud…*).

1. **Connect to an instance.** Paste the link code into the field and press
   **Connect**. The page shows the host and the certificate fingerprint before
   anything is sent; if your admin gave you the fingerprint, compare it.
   Copper pins that certificate: it talks to this server and nothing that
   impersonates it.
2. **Your account on this instance.** **Create account** (email, a password of
   at least 10 characters, and your name — shown beside your cursor on shared
   canvases), or **Sign in** if the account already exists.
3. **Browser sync.** Choose what syncs and press **Turn on sync**. The first
   sync merges this Mac with what the cloud already has; nothing is thrown
   away.

### What syncs

| Switch | What |
|---|---|
| Spaces and kept tabs | Every space (name, colour, icon, theme, order) and its pinned and saved tabs. Today's tabs stay on the Mac. |
| Settings | Look-and-behaviour settings only (appearance, sidebar, tab switching, sleep, ad blocking, autocorrect…). Never passwords, keys, accounts or agent setup. |
| Bookmarks | The whole tree. |
| Open tabs | This Mac's open tabs, shown on your other Macs under *On your other devices*. They never open by themselves. |
| History | Places visited, append-only. |
| Personal canvas | Your private board, under *Canvas*. Shared canvases are always live. |

**Passwords never sync.** Each switch takes effect at once; **Pause sync** ›
**Turn off** stops browser sync and the Personal canvas.

### A second Mac

On the Mac that is signed in: Settings › Cloud › **Pair another Mac** ›
**Make a code** (or <kbd>⌘K</kbd> › *Pair another Mac with Copper Cloud*). On
the new Mac paste that code into Settings › Cloud and press **Pair this
Mac** — it links and signs in in one step. A pairing code works once, for ten
minutes.

Pair rather than reusing your link code: a personal access key is often good
for one sign-in only (the admin's *Max uses*), so the same link code on a
second Mac may be refused.

## 4. The agent and Jev

### The agent pane

<kbd>⌘E</kbd> (**View › Agent**) opens a chat pane beside the page.
<kbd>⇧⌘E</kbd> (**View › Ask About This Page**, or <kbd>⌘K</kbd> › *Ask About
This Page*) opens it with the current page in front of the question. The agent
can read and act in your tabs with Copper's own tools; it can also use your
other MCP servers from `mcp.json` (Settings › Agents › *Open mcp.json*). Return
sends, <kbd>⇧↩</kbd> breaks the line, and the send button becomes Stop while it
works. <kbd>⌥⌘J</kbd> shows the driver timeline — who is driving the page and
what they are doing. <kbd>⌥⌘E</kbd> closes every pane.

### The model picker

The pill in the pane's header (and **Settings › Intelligence › Model**) picks
**Haiku** (quick), **Sonnet** (the balance, the default) or **Opus** (thinks
hardest). Each tier uses the latest model in its family — Opus is Opus 5.5.
The same choice serves the agent pane and Jev's typing and extract helper.

### Model access

**Settings › Intelligence › Use** has two lanes:

- **API key** — an OpenAI-compatible gateway (LiteLLM). On a Copper Cloud
  whose admin has set instance-wide keys, there is nothing to paste: once you
  are signed in to the cloud, Settings › Intelligence shows *Provided by
  Copper Cloud* and the agent pane and Jev just work. A key you enter yourself
  still takes precedence over the cloud's.
- **Claude account** (optional) — sign in with your own claude.ai account
  (Pro, Max, Team or Enterprise): **Sign in** opens claude.ai in a tab; finish
  there and it comes back. Requests then go straight to Anthropic on your
  account. `copper claude signin` does the same from a terminal.

**Test** on that page asks one question of each lane so you know it works
before you need it.

### Jev

Jev is the fast lane: it reads the controls on a page and picks the next
action in about a fifth of a second, so a whole goal ("find the March invoice
and stop when it is visible") runs in seconds instead of one round trip per
click. It needs a TypeSafe key, which a Copper Cloud with instance-wide keys
provides; otherwise make your own TypeSafe account at
[console.typesafe.ai](https://console.typesafe.ai), create a key there and paste it
under Settings › Intelligence › Jev (**Get a key** beside the box opens the console).
A Claude sign-in doesn't stand in for it: Jev runs need the key. For outside
agents, turn on **Settings › Agents › Let the agent hand Copper a goal**.

## 5. Connect phi or Claude Code

Let the coding agent in your terminal drive the browser you are already signed
in to.

1. **Settings › Agents › Let agents drive this window** — starts a local MCP
   server on `127.0.0.1` only, guarded by a token in a file only you can read.
2. Turn on **Let the agent hand Copper a goal** for Jev mode (recommended).
3. Under **Terminal agents**, press the button on the **phi** row, the
   **Claude Code** row, or the **copper CLI** row. Or from a terminal:

   ```sh
   copper setup phi       # writes ~/.pi/agent/mcp.json and the /jev prompt
   copper setup claude    # writes ~/.claude.json and the /jev command
   copper setup status    # ready / stale / missing for each
   ```

   Setup merges Copper's current token into your user config, so no token
   ever goes into a pasted prompt. Rotating the token (Settings › Agents ›
   **Rotate**) marks every client stale; run setup again.
4. In phi, or in a **new** Claude Code session, hand over a goal:

   ```text
   /jev find the Acme invoice for March 2026 and stop when it is visible
   ```

The `copper` command works on its own too: `copper tabs`, `copper run "…"`,
`copper observe`, `copper extract "…"`, `copper health`. It never starts Copper
unless you add `--launch`. Every agent action shows in the window — a pill
names who is driving, and the driver timeline (<kbd>⌥⌘J</kbd>) lists what they
did, with Stop.

## 6. Passwords

Copper offers to save a sign-in after it has actually worked, and shows your
saved accounts under the field when you click it — it never fills on its own.
They live in the macOS keychain by default (<kbd>⌥⌘L</kbd> opens the list).

**Bitwarden (optional).** Install the CLI (`brew install bitwarden-cli`), then
**Settings › Passwords › Bitwarden**: server (bitwarden.com, EU, self-hosted or
Vaultwarden), email and master password, **Sign in**; a two-step or new-device
code is asked for next if your account needs one. Fills then merge keychain and
Bitwarden accounts, one-time codes fill from the stored authenticator key, and
**Save new passwords to › Bitwarden** routes new saves there. **Stay unlocked
between launches** is on by default.

**1Password (optional).** Install the CLI (`brew install 1password-cli`), then
**Settings › Passwords › 1Password**: with the 1Password app on this Mac,
**Unlock with 1Password** — the app asks for Touch ID in its own window and no
password is typed into Copper (turn on 1Password › Settings › Developer ›
Integrate with 1Password CLI first). Without the app, sign in with the account
password, or paste a service account token on a Mac nobody sits at. Fills,
codes, addresses and cards then come from 1Password too, and **Save new
passwords to › 1Password** routes new saves there (docs/passwords.md).
Passkeys kept in 1Password come through the 1Password browser extension,
which signs in separately: Settings › Extensions › 1Password › Details ›
**Sign In…** (email, Secret Key, password), or **Use the 1Password App…**
to have 1Password allow Copper so the extension unlocks with Touch ID
(docs/passwords.md, The 1Password extension).

**Agents and passwords.** Agents never receive a password. They can only ask
Copper to fill a saved sign-in you allowed under **Settings › Passwords ›
Agent access** (per account, or share everything; in Bitwarden, items in a
folder named `Agents` are allowed; in 1Password, a vault named `Agents` or the
`copper-agent` tag).

## Troubleshooting

**"The server's certificate doesn't match the link code's fingerprint."** The
instance's certificate changed (rebuilt or re-issued), or something is in the
way. Ask your admin for a fresh link code and connect again.

**"The instance refused this key."** The access key was revoked or expired, or
the link code is for another instance. Ask your admin for a new link code.

**"This instance isn't taking new accounts."** Sign-up is closed; ask the admin
to create your account, then **Sign in**.

**"Nothing is listening there" / "Can't reach the cloud."** The instance is
down or your network can't reach it. Sync retries on its own; **Sync now**
tries at once. The log at the foot of Settings › Cloud has the last 200 lines.

**Not linked / signed out.** Settings › Cloud shows the steps that are not done
yet. A server that ends your session signs Copper out; sign in again.

**The agent says no model is set up.** Check Settings › Intelligence: signed
in to the cloud (for provided keys), a key of your own, or a Claude account.
Press **Test**.

**`copper` says the browser is not running or not set up.** Open Copper and
turn on Settings › Agents › Let agents drive this window, then run
`copper setup phi` (or `claude`) again.

**Move in can't read Chrome or Safari, but Copper is switched on in System
Settings.** The switch can belong to an older, unsigned Copper (see *Updates
are automatic*). Turn Copper off and on again in Privacy & Security › Files &
Folders (Chrome) or Full Disk Access (Safari), then come back to Copper.

**An update did not finish.** Settings › About › Updates shows the reason and **Open
log** (`~/Library/Logs/Copper/update.log`). Re-running the curl installer is
the manual path.

**Lost tabs after a quit or update?** <kbd>⌘K</kbd> › *Restore previous
session*, or `copper session restore` (add `--quit` if Copper is running).

### Where your data lives

Everything is in `~/Library/Application Support/Copper/`: `session.json`
(tabs and spaces), history and bookmarks, `cloud.json` (the cloud link and
session token, mode 0600), `intelligence.json` and `claude.json` (model keys
and the Claude sign-in, 0600), `cloud-intelligence.json` (keys your Copper
Cloud provides, 0600, gone when you sign out of the cloud), `agent.json` (the agent token, 0600) and
`mcp.json`. Passwords are in the macOS keychain (or Bitwarden). Site cookies
are in WebKit's store for the app. Copper sends no telemetry.

## Who to ask

Your Copper Cloud administrator issues link codes and accounts. Bugs and
ideas: **Help › Send Feedback…** (or Settings › About) opens a new issue on
[github.com/copper-browser/Copper/issues](https://github.com/copper-browser/Copper/issues)
with your Copper version, build and macOS already filled in; nothing is sent
until you file it.

More detail: [cloud.md](cloud.md) · [flow.md](flow.md) ·
[intelligence.md](intelligence.md) · [agents.md](agents.md) ·
[passwords.md](passwords.md) · [updates.md](updates.md)
