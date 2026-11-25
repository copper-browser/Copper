# iCloud sync — end-to-end encrypted, no server

*Settings › Cloud › iCloud sync. Code: `Sources/Search/Fork/FolderSync/`.
Tests: `swift test --filter FolderSync`, two worlds: `docs/fixtures/icloud-e2e.sh`.*

Copper syncs through a folder instead of a server. Every Mac reads and writes
sealed files in a folder you pick — `iCloud Drive › Copper` by default
(`~/Library/Mobile Documents/com~apple~CloudDocs/Copper`) — and whatever syncs
that folder carries them between Macs. No account, no server, no Apple
entitlement: iCloud Drive syncs any folder under it. Dropbox, a NAS or a USB
drive work the same way. A 24-word recovery phrase is the only key; the folder
holds nothing readable without it.

It sits beside [Copper Cloud](cloud.md) and never edits it: it reads this
Mac's state and writes merged state back through the same calls Copper Cloud
uses (`CloudApply`) and merges by the same rules (`CloudMerge`). When both are
on and Copper Cloud syncs spaces, iCloud sync leaves spaces to it (one owner
for the kept-tab keys); everything else can run through both.

The format follows Ardia's folder sync (its `docs/sync.md` › Folder layout,
Merge), which follows Dia's UX.

## Setting it up

- **Turn On Sync** makes a phrase, keeps it in the login keychain (item
  `Copper Sync Key`, never iCloud Keychain) and shows **Save your Recovery Kit**:
  the 24 words, a QR code of them, Save… (a one-page US Letter PDF, *Copper
  Recovery Kit.pdf*), Copy Words (marked concealed, so clipboard managers skip
  it) and Save as Text….
- **Enter Recovery Phrase…** on another Mac joins. Words are read leniently:
  any case, the kit's numbering, punctuation, and a word's first four letters.
  A phrase that isn't 24 BIP-39 words, fails its checksum, or doesn't match a
  chain in the folder is refused with Dia's words. When the folder already
  holds sync data, Enter Recovery Phrase… is the primary button.
- A joining Mac sends nothing until it has read the other Macs' files, so its
  defaults never beat what is synced; the first sync of each domain is then a
  union (Copper Cloud's first-sync rule: the folder wins where both have the
  same thing).
- If iCloud Drive is off, the page says so, links to iCloud settings and
  offers another folder. A test world never defaults to iCloud Drive: its own
  `Sync Folder` inside the world, unless given one (`bench icloud folder`).

On: the status line uses Dia's words (starting up · updating · updated just
now · offline · not syncing), plus "waiting for N files to download" while
iCloud hasn't brought files down. Below: Recovery phrase (Show Words and Save
Recovery Kit… behind Touch ID or the login password, good for a minute), the
sync folder (Show in Finder), Stop Syncing…, a switch per domain, and Devices
(each other Mac, its open tabs as a menu, when it last wrote).

**Stop Syncing…** removes this Mac's name and open tabs from the others,
forgets the key and keeps every bit of local data. Ticking *Also delete the
synced data* removes this phrase's folder; the other Macs then say *This
device is out of sync. Sync may have been reset from another device.* and stop,
keeping their data.

## Keys and files

- Phrase: BIP-39 English, 256 bits + 8-bit checksum (24 words). The wordlist
  is checked against its published SHA-256 in the tests.
- Keys: HKDF-SHA256 (salt `copper-sync/v1`) of the 256 bits → `file-key`
  (ChaChaPoly) and `name-key` (HMAC-SHA256). Nothing is stretched: the phrase
  already carries 256 bits.
- Layout: `<folder>/<chain>/<scope>/<random>.cps`. `chain` = HMAC(name-key,
  "chain"), `scope` = HMAC(name-key, "scope/main"), each cut to 128 bits in
  base32; file names are 128 random bits. Names say nothing about the data.
- A file is `CPS1 | nonce | ciphertext | tag`, sealed with associated data
  `CPS1<chain>/<scope>/<file>`: renamed, moved, cut short or flipped, it
  doesn't open (tested). Inside: length | JSON | zeros to the next KiB.
- Every write is whole: written in a temporary folder on the same volume and
  moved in under `NSFileCoordinator`; reads are coordinated too. iCloud stubs
  (`.name.cps.icloud`) and dataless files count as waiting and are asked for.
  A file that doesn't open is set aside (still read every cycle); it holds
  "waiting" for a day at most.

## Merge

Each Mac only ever creates files and never changes one, so the service never
sees a conflict.

- **log** — a batch of one device's changes, `seq` counting up per device.
- **snapshot** — a device's whole replica and the seqs it covers per device.

A record is `key → (h, v, o)`: a hybrid logical clock (fixed-width
`wall.counter.device`, so stamps compare as strings), the value (canonical
JSON) or nil for deleted, and the log that wrote it. Later clock wins, per
record: commutative, associative, idempotent (tested over shuffled,
duplicated orders). Logs past a gap wait; a snapshot never resurrects a
deletion it or this Mac already applied.

On top of the records, Copper Cloud's document rules: per domain the base
(records as last synced here), this Mac's copy and the folder's copy merge
three ways with `CloudMerge` — spaces (with intents: only what was changed
here by hand goes out), settings, bookmarks — and the result is applied
through `CloudApply` and what differs from the folder goes out as one log.
Copper Cloud's brake holds a spaces change that would unfile or remove more
than ten kept tabs on every Mac (Sync It / Undo Here).

Records: `sp:<id>`, `sp.order`, `kt:<key>`, `fd:<id>`, `fd.order` (spaces, kept
tabs, folders) · `set:<name>` (the settings allowlist, `CloudSettingsKeys`) ·
`bm:<id>` (bookmarks: parent, title, address, place) · `h:<key>` (history, 90
days) · `tabs:<device>`, `dev:<device>` (each Mac's open tabs and name) ·
`ext:<id>` (Chrome Web Store extensions).

## What syncs

Spaces and kept tabs (pins, Saved, folders — Today stays local), settings
(the allowlist only), bookmarks, history (90 days; applying takes the later
visit and the higher count, a page forgotten here isn't deleted elsewhere),
open tabs (to look at — nothing opens by itself), and extensions: one
installed from the Web Store here installs from the Web Store on the others
(the switch is the consent, as Move in's list is); one removed here is marked
removed and never uninstalled elsewhere. Folder-loaded extensions and every
extension's settings stay put. **Never passwords** in this version.

## Cycle and compaction

A cycle runs 3 s after an edit here, 1 s after the folder changes, every 20 s,
and on Sync Now:

1. The phrase's folder is still there (gone: reset elsewhere → stop).
2. A batch saved but not written goes out first, unchanged (crash-safe).
3. New files are read into the replica.
4. Per domain: merge, apply, publish one log.
5. Compaction: a snapshot when none was written for 10 minutes and the logs
   it newly covers number more than 40 and reach 400 or weigh a quarter of the
   last snapshot (with no snapshot yet, 40 are enough). Then files it covers go
   once they've been here an hour. A snapshot is only removed by one that
   covers it, so a Mac joining later always finds one whole. Tombstones older
   than 45 days (90 while a gap is open) and history older than 90 days are
   left out of snapshots.

State is kept in `folder-sync.json` (0600) in the data folder: the replica,
base, files read, pending batch.

## Bench

`./bench icloud status|folder PATH|on|join WORD…|phrase|off [delete]|now|set
DOMAIN on|off|doc DOMAIN|log|files|setting KEY VALUE|unbookmark URL|picture
PATH [dark]|kit PATH`. The phrase and anything that edits the browser answer
in test worlds only.

## Limits

- One scope (everything in one chain folder); per-profile scopes are later.
- Bookmark order is an index per folder: a move renumbers the folder's later
  items (fine at bookmark-folder sizes).
- No Send to Device yet, no sealed local state (`folder-sync.json` is plain,
  like `history.json` beside it).
