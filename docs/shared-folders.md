# Shared folders — a Saved folder shared through iCloud Drive

*Right-click a Saved folder › Share Folder…; New Tab's right-click menu or ⌘K ›
Add Shared Folder… on the other side. Code: `Sources/Search/Fork/SharedFolders.swift`
(engine), `SharedFoldersUI.swift` (menu, sheets). Tests: `swift test --filter
LiveSharedFolders`, two worlds: `docs/fixtures/folders-e2e.sh`.*

Arc had shared folders; Dia has none; Ardia brought them back (its
`docs/shared-folders.md`). Copper follows Ardia's model — a pinned folder bound
to a real directory in iCloud Drive, carried between people by iCloud Drive's
own folder sharing, no server, no CloudKit container, no entitlement — with one
change: the directory holds no readable links.

## What the person sees

- **Share Folder…** on a top-level Saved folder makes
  `iCloud Drive › Copper Shared › <name>` (`<name> 2` if taken), writes the
  folder's links into it and opens a sheet with two steps:
  1. **Share in iCloud Drive…** (the macOS share picker on the directory;
     Finder's Share › Share Folder works too) — this is what carries the
     directory to the other person.
  2. **Copy Invite Link** — `copper://folder/join?k=<key>&n=<name>` — or
     **Show Words**, the same key as 24 words to read out.
- **Add Shared Folder…** takes the link or the words, finds the directory in
  iCloud Drive (top level, where a folder shared with you appears, and one
  level down), and fills a new Saved folder from it. Not there yet: it says
  to accept the iCloud invitation first, and **Choose Folder…** picks it by
  hand. A `copper://folder/join` link from another app opens the same sheet.
- A shared folder wears two small people beside its name; red, with the
  reason on hover, when it isn't syncing. Its menu: Shared Folder… (the
  sheet), Copy Invite Link, Sync Now, Stop Syncing Folder….
- What syncs: the folder's links (the address and name they were shared with
  — browsing in a link's tab doesn't rewrite it), the folders inside it
  (`Trip › Deep`), adds, closes, moves between them, and the folder's name.
  A link arrives asleep, as a Saved row in its subfolder.
- **Stop Syncing** forgets the key on this Mac. The folder and its tabs stay
  here, and the directory stays with everyone else.

## How it works

- **A key per share.** 256 random bits, in the login keychain as
  `Copper Shared Folder` / `<chain>` (this Mac only, never iCloud Keychain;
  test worlds keep a 0600 file). The invite is that key, so neither the
  directory alone (what Apple holds) nor the invite alone (a link sent by
  text) shows a single address.
- **iCloud sync's sealed files.** The directory holds
  `<chain>/<scope>/<random>.cps`, the same format as iCloud sync
  (`Fork/FolderSync/`, docs/icloud-sync.md): HKDF keys, ChaChaPoly, HMAC
  folder names, every file bound to its path, padded to 1 KB steps.
- **Records and merge.** `name` and one `ln:<id>` per link
  (`{u, t, f, i}`: address, title, subfolder, place). Each Mac only adds
  files — a sealed log per batch of changes — into the same replica iCloud
  sync uses (per-record last-writer-wins by hybrid clock, logs applied once
  whatever order they arrive in). A cycle — 3 s after an edit, 1 s after the
  directory changes, every 20 s, on Sync Now — reads what is new, merges three
  ways against the base (what both sides last agreed, `SharedPlan`), applies
  the other side's changes to the sidebar quietly (Copper Cloud's brake
  doesn't count them as yours) and writes this side's.
- **The brake.** More than three links and more than half the folder gone
  from this Mac at once is held, not deleted for everyone: the sheet offers
  Delete for Everyone or Put Back.
- **Damage.** A file that won't open is set aside (counted, never read
  again); the folder goes on syncing.

## Limits

- One sealed log per change and no snapshots yet, so a busy folder's
  directory only grows (`shortcut:` in `publish`).
- Only top-level Saved folders can be shared; pins and Today rows aren't.
- Your other Macs get a shared folder through iCloud sync or Copper Cloud as
  an ordinary folder, the other person's changes included. Join it on one
  Mac only: joining on a second makes a second folder there.
- Whoever has both the directory and the invite can read and write; iCloud
  Drive's own sharing decides who has the directory.
