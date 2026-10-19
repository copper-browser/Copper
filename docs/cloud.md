# Copper Cloud — sync through an instance you run

*Settings › Cloud (or ⌘K › Copper Cloud…). Copper links to **one** self-hosted
[copper-cloud](https://github.com/Exowatt-Labs/copper-cloud) instance at a time,
signs in to an account on it, and syncs the parts of the browser you switch on
(*Browser sync*) and, if you choose it, your Personal canvas. Off until you turn
it on: before that nothing leaves the Mac but signing in. Shared canvases are
cloud documents by definition — that is what sharing means
([canvas.md](canvas.md)). Implementation: `Sources/Search/Fork/Cloud/`.*

## Setting it up

Three steps on the page, in order — or one, with a pairing code from a Mac
already signed in (see [Pairing another Mac](#pairing-another-mac)) or a
join link for your company's sign-in (see [Single sign-on](#single-sign-on-continue-with-google)):

1. **Connect.** One field, led by *Paste the link code or join link from your
   Copper Cloud administrator — or a pairing code from a Mac that is already
   signed in*;
   the page says which it got. A **link code** is what the instance's admin
   hands you — on an instance that keeps a directory of people, from the admin
   portal. Running your own server, `copper-cloud link-code` prints one (and
   `install.sh` prints it when it finishes):

   ```text
   copper-cloud://HOST:PORT/#k=<key>&fp=<sha256 of the certificate>
   ```

   The page shows the host and the certificate fingerprint before anything is
   sent; compare the fingerprint with `copper-cloud doctor` on the server if
   you want to be sure. **Connect** checks `/healthz` through the pinned
   certificate and that the instance accepts the key, then keeps the link.
   *Enter it by hand* takes the address, key and fingerprint as three fields.
   Once connected, this step folds to one line — *Connected to* the host, the
   start of the pinned fingerprint, and **Change…**, which opens the whole
   fingerprint and **Disconnect** — so the account form and its button stay in
   view below it (all of *Create account* fits a 760×640 window).

   **Access keys.** `k` is either the instance's shared key (an instance in
   `open` mode) or a **per-person access key**, `ck_…`, that the admin minted
   for you (an instance in `directory` mode, where the shared key no longer
   opens the door; the key may be tied to your email, so sign up with that
   one). Copper doesn't care which: it keeps whatever `k` is and sends it as
   `X-Copper-Instance` on every request. A revoked or expired access key makes
   the instance refuse this Copper ("The instance refused this key") — ask the
   admin for a new link code.
2. **Account.** *Sign in*, or *Create account* (email, a password of at least
   10 characters, the name shown beside your cursor on shared canvases). The
   first account on an instance is its admin; an instance can close sign-up
   after that, and then its admin creates accounts (`copper-cloud admin`).
3. **Sync.** Choose what syncs — the *Browser sync* switches and, under
   *Canvas*, *Personal canvas* — and press **Turn on sync**. The first sync
   merges this Mac with whatever the cloud already has — nothing on either side
   is thrown away.

After that the page shows, in order: the status (*Up to date · Last synced
just now*, or how long ago; *Syncing…* only while a sync is under way, and the
steps above say *Sync on*) with **Sync now**, and **Pause sync** › *Turn off*,
which pauses browser sync and the Personal canvas — shared canvases stay live;
the switches (each takes effect at once); the tabs open on your other devices
(*1 tab · Updated 2 minutes ago*); the account (sign out, rename this Mac);
**Pair another Mac**; the instance in one line, with *Details* for the
fingerprint and **Disconnect**; and a log. A field that takes focus or a
problem that appears is scrolled into view, and while more of the page is
below the panel's bottom edge, that edge fades with a small chevron (the
Settings scroll view has no scroller of its own).

## Pairing another Mac

A Mac already signed in can make a **pairing code** that links another Mac to
the same instance *and* signs it in as the same person — nothing to type on
the new Mac but one paste.

1. On the Mac that's signed in: Settings › Cloud › **Pair another Mac** ›
   *Make a code* (or ⌘K › *Pair another Mac with Copper Cloud*). The card says
   *Paste this into Settings › Cloud on the other Mac* over the code — the
   address, then the `cp_…` part large on a line of its own, then the
   fingerprint, wrapping inside the box — with **Copy**, *Expires in 9:58 ·
   works once* and a quiet red **Revoke**:

   ```text
   copper-cloud://HOST:PORT/#p=cp_<32 characters>&fp=<sha256 of the certificate>
   ```

2. On the new Mac: Settings › Cloud, paste it into the Connect field — it says
   *Pairing code — links this Mac and signs you in* — and press **Pair this
   Mac**. Copper reaches `/healthz` through the code's pinned certificate,
   sends the code to `POST /v1/auth/pair` (without the instance key: the code
   is the credential), and keeps what comes back — the link (address, the
   `gate_key` the server hands out, the fingerprint), the account and the
   session token — in one write. Then it turns on sync for everything (the
   switches it had before, if it was signed in once) and the steps land on
   *Sync on*; switch any domain off after.

A code works **once**, for **10 minutes**; making a new one on the card
revokes the one it showed. When the other Mac uses it, the card says so
(*Used — the other Mac is signed in*). A used, revoked or expired code is
refused with "That pairing code doesn't work any more …" — make a new one.

What the new Mac keeps as its key (`gate_key`) is the instance key on an
`open` instance, or — on a `directory` instance — a fresh access key the
server mints for it (labelled "<device> via pairing", tied to your email), so
the admin can revoke that one Mac without touching the others.

A code without `fp=` (an instance with a public certificate) is checked
against the Mac's own trust. If the Mac doesn't trust the certificate, the
page shows the fingerprint the server presented and offers *Trust and pair*:
compare it with `copper-cloud doctor` first; trusting it pins the instance to
that certificate from then on, exactly as an `fp=` would have.

## Single sign-on (Continue with Google)

An instance whose admin set up company sign-in (copper-cloud ≥ 0.9.0, Google
first) lets anyone with an allowed-domain account in without a link code, an
account to create or a password. Implementation:
`Sources/Search/Fork/Cloud/CloudSSO.swift`.

**Where the button appears.**

- **A join link** pasted into the Connect field — what `copper-cloud
  link-code --sso` prints and the instance's `/start` page shows:

  ```text
  copper-cloud://HOST:PORT/#sso=google&fp=<sha256 of the certificate>
  ```

  (`fp=` left out for an instance with a public certificate). The field says
  *Join link — links this Mac and signs you in with Google* and, once the
  instance has answered `GET /v1/auth/sso`, *Use your @exowatt.com account*;
  the button reads **Continue with Google** (the provider's name from the
  instance). There is no secret in a join link: the company account is the
  key.
- **Step 2, Account**, on an instance linked any other way: when its
  `GET /v1/auth/sso` lists a provider, *Sign in with your Google account* and
  **Continue with Google** come first in the card, above the password form.
  An instance with password sign-in off for everyone but its admins
  (`password_signin: false`) folds the form behind *Sign in with a password
  instead*. An instance from before single sign-on (404) shows the page as
  before.
- **`copper://cloud/join?code=<percent-encoded join link>`** — the `/start`
  page's *Open in Copper*. It opens Settings › Cloud with the code in the
  field and, for a join link, starts the sign-in at once, so the person is
  one click from Google's account picker. A link for another instance than
  the one this Mac is connected to changes nothing on its own: the page says
  *This link is for HOST* and how to switch (disconnect, then open it again).
  Already signed in there, it just says so. The `copper://` scheme is the one
  `build.sh` registers for canvas links; the link is taken wherever a
  `copper://` link arrives (another app, the address bar, a page in Copper).

**What pressing it does** (the native-app loopback flow, RFC 8252, with PKCE
S256):

1. `GET /v1/auth/sso` (no instance key, no session) through the pinned
   certificate — the join link's `fp`, or the linked instance's — for the
   provider's `client_id`, `authorization_endpoint`, `scopes`, `domains` and
   `hd`.
2. A listener on `127.0.0.1`, on a port the system picks, for one redirect.
3. The system's default browser opens at the provider with `client_id`,
   `response_type=code`, `scope`, `redirect_uri=http://127.0.0.1:<port>/`, a
   random `state`, the S256 `code_challenge`, `prompt=select_account` and
   `hd` when the instance gives one. The card says *Finish signing in in your
   browser…* with **Cancel**.
4. The browser comes back to the listener. A redirect without this attempt's
   `state` is turned away and the wait goes on. Copper comes to the front,
   sends `{code, code_verifier, redirect_uri, device}` to
   `POST /v1/auth/sso/google` (again without the instance key), and the
   browser tab shows *You're signed in — return to Copper* (or what went
   wrong, in the same words as the page).
5. The answer is kept exactly as a pairing's is (`Cloud.adoptSignedIn`, one
   write: the link with `gate_key` as its key, the account, the session token,
   the device id the server answered with), and sync turns on for everything,
   as after a pairing (`CloudPairing.syncAfterSignIn`).

The client secret never comes to the Mac — the server trades the code and
the verifier at the provider and checks the ID token (the issuer, the client,
a verified email in an allowed domain). The code, the verifier and the state
are never written down or logged. Nothing coming back within **5 minutes**
ends the wait (*Nothing came back from the browser in 5 minutes — try
again*); **Cancel** closes the listener at once.

**Refusals, in words:** `sso_domain` → *Use your @exowatt.com account* (the
domains the instance listed); `sso_no_account` → there's no account for that
email and the instance doesn't create them; `account_disabled`;
`sso_disabled` → single sign-on is turned off on the instance; `sso_failed`
→ Google didn't confirm the sign-in; `bad_redirect`; too many tries. A join
link without `fp=` to an instance the Mac doesn't trust shows the fingerprint
it presented and *Trust and continue with Google*, as a pairing code does.

From a script: `./bench cloud sso CODE` (or, linked, `./bench cloud sso`)
opens the browser and answers when the sign-in has finished, failed, been
cancelled or timed out; `--follow` makes Copper fetch the provider page
itself, for a pretend provider that redirects straight back;
`./bench cloud sso discover [CODE]` prints what the instance offers. The pure
parts (join links, discovery, the authorization address, PKCE, the callback,
the refusals, `copper://cloud/join`) are in `./bench cloud selftest` and
`swift test --filter CloudSSOTests`, which also runs the listener and both
requests against a pretend instance on this Mac.

## What syncs

| Switch | What | Notes |
|---|---|---|
| Spaces and kept tabs | Every space — name, colour, icon, theme, profile *name*, order — and its pinned and Saved tabs | Today's tabs stay on the Mac. A tab is matched across Macs by its space, its section and its site, so browsing inside a pinned tab doesn't resend anything; its address is the one it had when it first synced. Tab groups/folders, the order of pins within a row, and a theme's own picture (a file in `themes/`; the built-in ones work) don't travel. A profile is a name: the cookie jar behind it is never synced. |
| Settings | The allowlist below | Never passwords, passkeys, paths, keys, accounts or agent setup. |
| Bookmarks | The whole tree, ids and folders kept | |
| Open tabs | This Mac's open (non-pinned) tabs, for the others to see under *On your other devices* | One way: another Mac's tabs never open here by themselves — click one to open it. Turning the switch (or sync) off publishes an empty list. |
| History | Places visited | Append-only: pushed oldest first, at most 500 a request (fewer if the cloud says so), from where the last push stopped; pulled from where the last pull stopped. A title too long for the cloud is shortened; an address too big to store stays on this Mac (the log says so). Clearing history here, or forgetting a page in the History window, deletes it on the cloud too (copper-cloud 0.8.0); other Macs keep what they already have. |

Those five are *Browser sync*. The page shows the **Personal canvas** switch
apart from them, under *Canvas*, once CloudSync has it: Personal's room
connects only while it is on, and *Turn off* pauses it with the rest — see
[canvas.md](canvas.md). Shared canvases ignore every switch here.

### The settings allowlist

Only these `Store.settings` keys sync, and only with values of the expected
shape (`CloudSettingsKeys` in `Fork/Cloud/CloudMerge.swift`):

| Key | Setting |
|---|---|
| `look` | Light / Dark / System |
| `sidebar` | Tabs in a sidebar |
| `glyph` | Letters or site icons |
| `tabs.switching` | ⌃Tab: next in the row or most recent |
| `tabs.sleep` | Put idle tabs to sleep |
| `spaces.swipe` | Swipe between spaces direction |
| `shield` | Block ads and trackers |
| `autocorrect` | Correct spelling in pages |
| `sections.archive` | When Today rows are archived |

Deliberately left out: `bench` (the script socket), `passkeys*`,
`passwords.*`, `autofill.everything`, `downloads` and `downloads.ask` (a path,
and where files land), `sidebar.width` (a screen's business), `welcomed`,
`settings.page`, everything in `agent.json`, `intelligence`/model keys,
Bitwarden, extensions and their grants.

## How merging works

`spaces`, `settings` and `bookmarks` are whole documents on the server, each
with a version. Every change here waits two quiet seconds, then the domain's
document is built from the live objects (Spaces, Preferences, Bookmarks) and,
if it differs from the copy last synced, `PUT` with that copy's version as
`base_version`. If another Mac wrote first the server answers 409 with its
copy, and Copper merges **three ways** — the copy last synced (the base),
this Mac's, the server's:

- changed on one side only → that side's;
- changed on both → **the server's** (for settings, key by key);
- missing on one side but in the base → deleted there, stays deleted (unless
  the other side edited it meanwhile — then the edit survives);
- not in the base → new, kept. With no base at all (the first sync) it is a
  plain union, the server winning where both have the same thing.

Bookmarks merge node by node (id, parent folder, title, address); a node whose
folder is gone surfaces at the top level rather than disappearing. Space order
follows the server unless only this Mac reordered.

The merged document is written back here **through the same objects the UI
uses** — `Spaces` edits, `Preferences` properties, `Bookmarks.replace` (one save),
`History.take` — with an `applyingRemote` guard so the write doesn't count as
a change, and is then `PUT` again. Pulls happen at sign-in, at *Turn on sync*,
whenever the event stream (re)connects, and on each `doc`/`history` event
another device's write causes (`GET /v1/sync/events`, server-sent events,
reconnecting after 1, 2, 4 … 30 s with jitter).

History is not a document: new visits go up with `POST /v1/sync/history`
(cursor `pushedThrough`, the newest visit already sent), other devices' come
down with `GET /v1/sync/history?since=…&exclude_device=me` (cursor
`pulledSeq`). A visit already known within one second is skipped; one merged
in from elsewhere is remembered so it isn't sent back up.

Pushing never gets stuck on one visit (`Fork/Cloud/CloudHistory.swift`). The
cloud's limits come from `GET /v1/info` (`max_history_entry_bytes`,
`max_history_batch`; copper-cloud's defaults, 16,384 bytes and 2,000, when it
doesn't say), and every entry is encoded once — keys sorted, slashes as they
are — measured, and sent as those bytes:

- a title that makes the entry too big is shortened (with *…*) to fit; an
  address too big on its own is left out — a cut address is another place —
  and the log says *History: left out a visit to HOST (…, N bytes)*, never the
  address itself;
- `visited_at` is always a time the server reads: never later than now, never
  before 1601;
- a request the cloud refuses (400, 413, 422) is split in halves until the
  refused visit stands alone; that one is skipped and logged, the rest goes up,
  and no refused request is sent again. A 0.4.0 refusal that names the entry
  (`entry 3 …`) skips it at once; one that names a smaller limit (`exceeds N
  bytes`, `at most N entries`) is believed, and a 413 halves the request size,
  for the rest of the push. A 0.5.0
  cloud stores what it can and lists what it skipped (`rejected`), which is
  logged the same way;
- eight refusals in a row with nothing accepted between them is the cloud
  refusing history, not one visit: the push stops and nothing more is skipped;
- after any failed push the next automatic one waits 30 s, then 1, 2, 4, 8 and
  15 minutes; *Sync now*, sign-in and turning History on don't wait.
  `cloud status` shows `historyRetryAt`.

`pushedThrough` moves after each request, only past visits that went up or
were left out — never past one still to send (visits at the same instant keep
it just short of that instant) and never past now. A visit stamped in the
future (a bad import, another Mac's clock) goes up with the time now and is
remembered beside the merged-in ones, so it isn't sent again and doesn't hide
everything visited until then.

### Deleting history on the cloud

Only the person picks what goes, and only this Mac reads history to find it
(`Fork/Cloud/CloudHistoryDelete.swift`). A copper-cloud that lists
`history_delete` in `GET /v1/info`'s `features` (0.8.0) takes `DELETE
/v1/sync/history` in two shapes, never mixed: a body `{"seqs": […]}` (at most
5,000), or the query `since` (inclusive), `until` (exclusive), `device` — none
of them is everything. It never filters by what a visit is.

- **A time range, a device, everything:** one request with those filters.
- **A site or a page:** this Mac pages through the account's history (`GET
  /v1/sync/history?since=SEQ&limit=500`, no `exclude_device`, at most 1,000
  pages), matches each row here — a site with its subdomains (`x.com` takes
  `www.x.com`, not `notx.com`), a page by its History key — and deletes the
  matches by seq in batches of 5,000. A stop while looking deletes nothing;
  once deleting starts it finishes.

Where: Settings › Cloud › *Delete history on cloud* (last hour, 24 hours, 7
days or all time, optionally one site; one confirmation; *Deleted N visits
from the cloud*); `copper cloud-history delete` and the loopback-only MCP
tool `cloud_history_delete` (refused to the agent pane and to agent-link
bots); and, while History syncs, *Clear History* here (everything) and
forgetting a page in the History window (that page's rows, from every Mac).
History on this Mac is never changed by a delete on the cloud, and other Macs
keep what they pulled. Without the feature the card says the cloud can't and
the mirrors only log it. `history_deleted` events are ignored.

Nothing deleted comes back. A delete runs in the history lane — after any
push or pull in flight, before the next. A push only sends visits newer than
`pushedThrough`, which a delete never moves back; covered visits here not yet
pushed are recorded as on the server already, so the cursor passes over them.
Clearing here moves `pushedThrough` to now. A page forgotten here is kept out
of pushes for the run in case `history.json` hasn't been rewritten yet. A pull
only asks for seqs after `pulledSeq`, and deleted rows are gone.

The per-domain state — the last-synced copy of each document and the history
cursors — lives in `cloud-sync.json` (0600) beside `cloud.json`; signing in as
another account starts it over.

## Security model

- **Pinning.** A self-signed instance's link code carries the SHA-256 of its
  leaf certificate (DER). Copper accepts the server's TLS certificate **if and
  only if** its fingerprint is that one — the Mac's trust store isn't
  consulted, so a self-signed instance works and nothing else can stand in for
  it, whatever CA signed it. A code without `fp=` (an ACME certificate) uses
  the system's normal validation. Every request, the event stream and canvas
  WebSockets go through the same pinned `URLSession`.
- **The instance key** (`X-Copper-Instance`) is sent with every `/v1` request;
  without it the server answers nothing but `/healthz`.
- **The session token** is a bearer token minted at sign-in. It lives in
  `~/Library/Application Support/Copper/cloud.json`, mode 0600, written
  atomically and private from its first byte — never the macOS keychain, never
  `Store.settings`, never published to the UI, never logged, never in a bench
  or MCP status. A 401 `session` from the server signs this Copper out.
- **Plain HTTP** is accepted only for a loopback host (`127.0.0.1`,
  `localhost`, `::1`) — a development server running with `tls off`. Use
  `http://127.0.0.1:PORT/#k=KEY`, or a link code with `&tls=off`.
- **On the server** every document and history entry is encrypted at rest
  with the account's data key (AES-256-GCM), itself wrapped by the instance's
  master key. The instance's operator can still read them — run your own, or
  use one run by someone you trust.
- **Passwords** go to the server only to sign up or sign in, over the pinned
  connection, and are not kept.
- **Pairing codes** (`cp_…`) are minted by the server, which keeps only their
  SHA-256; single use, ten minutes, revocable. Copper shows the one it made on
  the card and copies it to the clipboard when asked — it is never written to
  `cloud.json`, never logged and never in `cloud status` (only its id and
  expiry are). On the receiving Mac the code is sent once, over the pinned
  connection, and forgotten.

**Model keys.** A cloud may also hand every signed-in Copper the Jev and
gateway keys (`GET /v1/intelligence`); they are kept in
`cloud-intelligence.json` (0600), never in `intelligence.json`, never shown
unmasked, never in any status, and deleted on sign-out or disconnect. While
the cloud provides a gateway key, every model call uses it — the gateway lane
with the cloud's key and address, even with a Claude account signed in; the
lane chosen on the Mac is kept and back in force after sign-out. A Jev key
typed on the Mac wins. The same answer may set the org's agent tool-call
rounds per question (`agent.max_turns`), which wins over the Mac's own while
signed in. See [intelligence.md](intelligence.md#keys-from-copper-cloud).

`cloud.json` holds: the device id (minted once per data folder, so each probe
world is its own device) and name, the link (address, key, fingerprint), the
account (user id, email, name, device id), the token, and the sync switches
and history cursors.

## Troubleshooting

- **"The server's certificate doesn't match the link code's fingerprint"** —
  the certificate changed (re-issued, or a different server at that address).
  Get a fresh link code from the server and connect again; if the server
  didn't change, something is in the way.
- **"Nothing is listening there" / "No such host"** — the address or port is
  wrong, or the instance is down: `copper-cloud doctor` on the server.
- **"The instance refused this key"** — the code is from another instance, or
  the key was rotated. Copy the link code again.
- **"This instance isn't taking new accounts"** — sign-up is closed; ask the
  admin to create the account.
- **"Too many tries"** — sign-in (and pairing) is rate-limited per address;
  wait a minute.
- **"That pairing code doesn't work any more"** — it was used already,
  revoked, or is past its ten minutes. Make a new one on the other Mac.
- **"This instance doesn't take pairing codes yet"** — the server predates
  them; update copper-cloud, or connect with a link code and sign in.
- **"This Mac doesn't trust the instance's certificate, and the pairing code
  has no fingerprint"** — the code came from an instance without `fp=`; compare
  the fingerprint shown with `copper-cloud doctor` before *Trust and pair*.
- **Status stays "Can't reach the cloud"** — sync retries on its own once the
  event stream reconnects; **Sync now** tries at once. The log (at the foot of
  the page) has the last 200 lines.
- **"History: left out a visit to …"** — that place's entry is bigger than
  the cloud takes (`max_history_entry_bytes`); it stays in History on this Mac
  and everything else syncs. *History: the cloud refused …* followed by *trying
  again in N s* means the cloud is refusing history itself — its log says why.
- **Something didn't sync** — check the switch is on for that domain and the
  log says *Pushed …*/*Pulled …*. Remember what doesn't travel (Today tabs,
  groups, pictures, the non-allowlisted settings).

## Driving it from a script

In a probe world (never your own Copper), with *Let a script drive Copper* on:

```sh
./bench --world NAME cloud link 'copper-cloud://127.0.0.1:8443/#k=…&fp=…'
./bench --world NAME cloud signup you@example.com a-long-password Your Name
./bench --world NAME cloud sync on spaces,settings,bookmarks,tabs,history
./bench --world NAME cloud status          # no secrets in it
./bench --world NAME cloud devices         # other devices' tabs
./bench --world NAME cloud doc spaces      # this Mac's document as it would be pushed
./bench --world NAME cloud selftest        # link codes, the allowlist, the merges, history pushes and deletes against a pretend cloud
./bench --world NAME cloud wstest          # a canvas WebSocket through the pinned session
./bench --world NAME cloud picture /tmp/cloud.png [dark] [CODE]   # the whole page, drawn off screen
./bench --world NAME cloud pairing-code    # signed in: a code for another Mac → {id, code, link, expiresAt}
./bench --world OTHER cloud pair 'copper-cloud://…/#p=cp_…&fp=…'   # links + signs in + turns on sync
./bench --world NAME cloud pairing-codes   # my codes still open
./bench --world NAME cloud revoke-pairing ID|current
./bench --world NAME cloud sso 'copper-cloud://…/#sso=google&fp=…'   # Continue with Google: browser, then signed in + sync on
./bench --world NAME cloud sso discover [CODE]   # what GET /v1/auth/sso offers (CODE, or the linked instance)
./bench --world NAME cloud sso state|cancel
```

`cloud pair CODE` takes the whole code, or a bare `cp_…` on a Copper already
linked to that instance; `--sync DOMAINS|all|none` chooses what turns on
afterwards (default: what the page does), and `--trust FINGERPRINT` answers the
trust-on-first-use question for a code without `fp=` (the refusal carries the
fingerprint the server showed as `seen`). `cloud picture … CODE` draws the page
with CODE already in the Connect field, to see what it makes of it.

Also `cloud signin EMAIL PW`, `signout`, `disconnect`, `sync off|now`,
`sync set DOMAIN on|off`, `log`, `history-limits` (what a history push
believes the cloud takes; `history-limits ENTRY_BYTES BATCH`, in test worlds
only, plants a stale belief so a push meets the cloud's own refusals), and — in test worlds only — `bookmark URL
[TITLE]`, `pin URL` and `open URL` to make something worth syncing. The bench
splits its words on spaces, so a password given there can't contain one (the
page has no such limit). Two probe worlds on one Mac are two devices:

```sh
defaults write com.officecommun.search.test.one bench -bool true   # before launch: the script socket
open -n -g --env SEARCH_PROBE=one --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT=4151 build/Copper.app
./bench --world one cloud status
```

## For the canvas and other callers

`Cloud.shared` is the one client: `request`/`requestJSON` (instance key,
bearer token, JSON, 15 s, GETs retried, `Cloud.Failure` from the server's
`{error, message}`), `socket(path:query:)` for a pinned WebSocket
(`CloudSocket`: binary frames, ping every 20 s, reconnecting is the caller's),
`Cloud.didChange` when the link, account or reachability changes, and
`Cloud.event` for each server-sent event (`type`: `doc`, `history`, `canvas`,
plus `open`/`ready`/`resync` when the stream (re)connects).

Pairing (`Fork/Cloud/CloudPairing.swift`, `Cloud.pair` in `Cloud.swift`):
`Cloud.parseCode(text, linkedTo:)` → `.link(Link)` | `.pairing(PairingCode)`
(`parseLinkCode` still answers only link codes); `pair(_:trusting:)`;
`mintPairingCode(deviceName:)` → `MintedPairing {id, code, link, expiresAt}`;
`pairingCodes()`; `revokePairingCode(_:)`. `CloudPairing.shared` is the one
code this Copper is showing (card, ⌘K and bench share it), and
`CloudPairing.pairAndSync` is what the page's *Pair this Mac* runs.
Single sign-on: `Cloud.discoverSSO(url:pin:)` and
`Cloud.exchangeSSO(…)` are the two requests; `CloudSSO.shared` is the one
sign-in under way (`start`, `cancel`, `phase`), shared by the page,
`copper://cloud/join` (`CloudJoin`) and the bench; both it and pairing end in
`Cloud.adoptSignedIn` and `CloudPairing.syncAfterSignIn`.

## TODO

- Sync a pinned tab's order within its row, tab groups, and theme pictures.
- Device management (list and remove devices) on the Cloud page; the server
  already has `GET/PATCH/DELETE /v1/devices`.
