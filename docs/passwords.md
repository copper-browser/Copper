# Passwords in Copper

Copper keeps its password sources side by side:

- **The macOS keychain** remains the default save destination.
- **Bitwarden** is an optional backend driven by the official `bw` command-line
  client. When it is connected, fills merge keychain and Bitwarden accounts;
  choosing Bitwarden only changes where new save offers go.
- **1Password** is an optional backend driven by the official `op` command-line
  client, with the same shape as Bitwarden — see [1Password](#1password).

**Save new passwords to** (Settings › Passwords › Password managers, shown once
a manager is connected) chooses Keychain, Bitwarden or 1Password for new save
offers. A chosen manager that is locked sends saves to the keychain until it
opens, and the line says so. Fills always merge every unlocked source.

Copper never needs a browser extension for either source. A saved account is
read only when the user picks it (or an agent is allowed to use it), not while
the picker is being drawn.

## Speed, staying unlocked, and updates

- After unlock Copper reads the item list once (and every five minutes) and keeps
  it in memory — names, sites, and the secrets that came with it. A pick fills
  at once; one-time codes are computed locally from the stored seed (`bw get
  totp` is the fallback for formats Copper does not parse). Locking clears all
  of it.
- **Stay unlocked between launches** (on by default, Bitwarden card) keeps the
  session key in a 0600 file beside Bitwarden's own data under Copper's support
  folder, so the vault opens with the app. Turn it off to be asked for the
  master password once per launch. Lock deletes the file.
- Saving a sign-in whose account already exists in Bitwarden for that site
  **updates that item's password** instead of adding a twin.

## Connect Bitwarden

Install the CLI first:

```sh
brew install bitwarden-cli
```

Then open **Settings › Passwords › Bitwarden**. Enter the server, email and
master password, then choose **Sign in**. When the account wants more, the card
asks for it next, the way `bw login` itself does:

- **Two-step login by email.** Bitwarden sends the code when the password has
  been accepted — not before — so the card says *Enter the code Bitwarden
  emailed*, with **Send again** beside it. The newest email is the one that
  counts.
- **Authenticator app or YubiKey.** *Enter your authenticator app code* /
  *Touch your YubiKey*.
- **Several methods on the account.** The card lists them (Authenticator app,
  Email, YubiKey); pick one and the code step follows.
- **A Mac that has not signed in before, on an account without two-step
  login.** Bitwarden emails a new-device verification code; the card asks for
  it the same way.

A code that is refused ends that `bw`; the card starts a fresh sign-in at once
(and a fresh email goes out, when that is the method) and says so, so the next
code has somewhere to go. **Cancel** lets the waiting `bw` go. The card waits
ten minutes for a code, then gives up and says so.

Under the hood `bw login` runs *with its prompts on* — stdin, stdout and stderr
are pipes, stderr is watched for the prompt (`Two-step login code:`,
`Two-step login method:`, `New device verification required…`), and the code is
written to stdin when you have it. Every other `bw` command still runs with
`BW_NOINTERACTION`. Why and how, with the verification rig:
[plans/2026-09-30-bitwarden-two-step-codes.md](plans/2026-09-30-bitwarden-two-step-codes.md).
The server field accepts:

- Bitwarden cloud: `https://vault.bitwarden.com`
- Bitwarden EU: `https://vault.bitwarden.eu`
- a self-hosted Bitwarden server; or
- a Vaultwarden server (use the server URL it provides).

Copper passes the password to a short-lived `bw` process through its environment,
never as a command-line argument. It gives `bw` a Copper-owned appdata directory
under the current Copper support folder, so it does not read or mutate the
user's normal Bitwarden CLI directory. Probe worlds have their own support
folder as well.

After sign-in or unlock, Copper holds the Bitwarden session key in its process
memory and — only while **Stay unlocked between launches** is on — in the 0600
`session` file described below. Locking clears the key, the file and the
in-memory metadata. It is expected that an external `bw status` can report
`locked` while Copper's Settings card says `Unlocked`: the external CLI has no
Copper session key. With Stay unlocked off, relaunching Copper starts locked;
unlock it from Settings with the master password.

**Sign out** (on the card's Locked line, and on the Account line while
unlocked) locks, forgets the account and its cached data on this Mac, and
brings the sign-in form back — for another account or another server. Nothing
in the vault changes.

The auto-lock picker is **5 minutes**, **15 minutes**, **60 minutes**, or
**Never**. The default is **Never**. A background metadata refresh runs every
five minutes while unlocked; a cold `bw` start is about 2.5 seconds, so the
picker uses an in-memory cache instead of launching `bw` for every row.

While Bitwarden is unlocked, the in-memory cache holds matching metadata and the
values needed for an immediate fill: passwords, TOTP seeds, identity details,
card numbers/CVV, notes, and custom-field values. It is protected by the same
process boundary as the session key, is never returned over MCP or the CLI, and
is wiped (including identity/card values) when you lock the vault.

## Fills and saves

The under-field picker combines keychain and Bitwarden candidates. Select a row
to fill it.

**Two-step codes.** Click a one-time-code box and the list shows a *Two-step
code* row for every Bitwarden login on the site that has an authenticator key;
the account you just signed in with in that tab comes first, since the code
page is often on another host (accounts.google.com, login.microsoftonline.com).
Pick it and Copper works out the current code from the stored seed and fills
it — one box, or one box per digit. Codes kept only in the separate Bitwarden
Authenticator app are invisible to `bw`: the key has to be on a Password
Manager login item with the site's URL.

Keychain logins can keep a code too. In the Passwords panel, open the site,
hover the account and press **Add code**, then paste the setup key the site
shows during two-step setup (the "can't scan it?" text under the QR code) or
its `otpauth://totp/…` link. Copper checks that the key makes a code before
keeping it. The key is a separate keychain item under **Copper Codes**. It is
never shown, and it is removed with the login. A CSV import keeps the
`otpauth`/`totp` column the same way.

**Filled on their own.** With Settings › Passwords › **Fill two-step codes**
on (the default), Copper watches for the code page after a sign-in. If the
account you just signed in with in that tab has a key, Copper fills the box
without a click. That account is either the one you picked from the list or
the name the page just sent. The fill happens once per sign-in, within ten
minutes, and only on a page where that account would be offered anyway. The
box must plainly be a code box: `autocomplete="one-time-code"`, a row of
one-digit boxes, or a name such as OTP, 2FA or verification code. Copper
never presses the page's button. Codes texted or emailed to you are not
read.

Choose **Bitwarden** under **Save new passwords to** (Settings › Passwords ›
Password managers) to route new save offers there while it is unlocked; choose
Keychain (or leave Bitwarden locked) to keep saving to the keychain. Existing
fills continue to include every source.

## Autofill everything

Turn on **Fill addresses and cards** in Settings › Passwords to let the
under-field picker fill more than sign-ins (`prefs.fillsEverything` is on by
default). Click any recognised field in a checkout or address form:

- **Identities** fill a name, email, phone, company, street lines, city, state,
  postal code, and country as one group. Copper shows the identity name and a
  short address summary, never the private values in the row.
- **Cards** fill the cardholder, number, expiry, brand, and security code as one
  group. Card numbers and codes stay in memory only while unlocked.
- **Custom fields** are matched by a field's name, id, placeholder, or label to
  a custom field on a login item for the current host. Hidden custom fields are
  treated like passwords and are never listed with their values.
- **Most-used usernames** appear on an email or username field even when there
  is no saved account for that site. They are deduplicated and limited to the
  eight most-used names (then identity emails/usernames).

Agent access applies to identities and cards as well as login credentials. Open
Settings › Passwords › Agent access and enable a per-item toggle (or the
share-everything switch) before an agent can use one. The picker itself can
still use every unlocked item; the agent allow-list only gates agent fills.

## Signing in without a window: `copper bitwarden` and the headless Mac page

A headless Copper (a headless Mac mini's LaunchAgent, docs/headless.md) has no
Settings window to type into. The same backend is driven through the loopback
agent server's `copper/bitwarden` method (127.0.0.1 + the bearer token in
`agent.json`; the agent link refuses every `copper/*` method, so no bot can
reach it) and its CLI:

```sh
copper bitwarden status                    # JSON report (default)
copper bitwarden login - < payload.json    # sign in + unlock; ONE JSON object on stdin
copper bitwarden cancel                    # let a sign-in that is waiting for a code go
copper bitwarden lock | logout | sync
copper bitwarden policy [--share folder|all] [--stay-unlocked on|off]
```

`login -` reads `{server?, email, password, clientId?, clientSecret?, otp?,
otpMethod?, share?, stayUnlocked?}` from stdin. Secrets are refused on argv, so
they never show up in `ps`. The headless Mac page seals the same object in the
owner's browser to the Mac's device key; an external daemon decrypts it in
memory and pipes it into `copper bitwarden login -`. The service only ever
relays ciphertext.

What `login` does, in order:

1. `bw config server <server>`, but only when the CLI is signed out. With no
   `server`, and no server configured in the CLI, it uses
   `https://vault.bitwarden.com`. Only `https://` URLs are accepted, plus
   `http://` to this Mac for a local Vaultwarden.
2. If the CLI is already signed in to another account or server, `bw logout`
   first. The same account on the same server is kept as it is.
3. **API key** (recommended for an unattended Mac): with `clientId` +
   `clientSecret` (Bitwarden web vault › Settings › Security › Keys › View API
   key) it runs `bw login --apikey`, passing `BW_CLIENTID` / `BW_CLIENTSECRET`
   only through the child's environment. This skips the two-step prompt and
   new-device email verification. It leaves the account signed in but
   **locked**.
   **Email + master password** otherwise: `bw login EMAIL --passwordenv
   BW_PASSWORD` with its prompts on, plus `--method N` when `otpMethod` is
   given and `--code OTP` when `otp` is. N is 0 for an authenticator app, 1 for
   email and 3 for YubiKey OTP; a code with no method is sent as an
   authenticator code. When `bw` asks for a code that the call did not carry,
   the answer is `ok: false` with `needs: "code"`, `prompt` (`twoStep` |
   `newDevice`), `method` (the one asked for, or `null` when the account has
   one method and the CLI picked it) and `pending: true` — `bw` is holding the
   sign-in open for ten minutes, and the email has gone out when the method is
   email or the prompt is `newDevice`. **Call `login` again with the same
   `email` and the `otp`** to finish. When the account has several methods and
   none was named, the answer is `needs: "method"` with `methods: [{id, name}]`;
   call again with `otpMethod`. `copper bitwarden cancel` lets a waiting sign-in go.
4. `bw unlock --passwordenv BW_PASSWORD` when the vault is locked. The master
   password is always required, because it is what decrypts the vault.
5. Applies the policy: `share` `folder` | `all` (below) and `stayUnlocked`.

Every answer is `{ok, cli, cliVersion, state
(missing|unauthenticated|locked|unlocked), email, server, lastSync,
agentAccess (folder|all), stayUnlocked, counts {logins, identities, cards}}`. A
failure adds `error`: one line of at most 200 characters, with anything the
caller sent as a secret cut out. No answer ever holds a password, API secret,
session key or vault value. Exit codes: 0 `ok`, 1 `ok: false`, 2 usage or Copper
unreachable.

`bw` itself is found in this order: `SEARCH_BW_PATH` (the daemon points its
LaunchAgent at the CLI it installed), `/opt/homebrew/bin/bw`,
`/usr/local/bin/bw`, then `$PATH`.

**What is stored where:**

| Where | What | Who writes it |
|---|---|---|
| `<Copper support>/bitwarden/` (0700; `bitwarden (<world>)` in a probe world) | `bw`'s own `data.json`: the encrypted vault, auth tokens, and, after an API-key login, the client secret it keeps for token refresh (the Bitwarden CLI always does this) | `bw` |
| `<Copper support>/bitwarden/session` (0600) | the session key, only while *stay unlocked* is on | Copper |
| Copper's defaults | server URL, *stay unlocked*, agent-access policy | Copper |

Nothing of Copper's writes a master password, or an API secret, to disk.
**Lock** drops the session key and its file. **Sign out** (`logout`) wipes the
CLI's account state. Turn *stay unlocked* off to need the master password after
every restart, and keep FileVault on for the Mac.

**Agent policy:** `share: folder`, the default, lets agents use only items in
the Bitwarden folder named `Agents`, items with `copper-agent: allow`, and
accounts shared one by one in Settings. `share: all` shares everything
(Settings' share-everything switch). `copper-agent: deny` always wins. Either
way, agents never receive the secret itself (next section).

## 1Password

Copper reads 1Password through the official CLI, `op` 2.x — the browser
extension route is closed to Copper (1Password's desktop link checks the
browser's code signature, and Copper's is its own certificate, not a Developer ID). Install it first:

```sh
brew install 1password-cli
```

Copper looks for `op` at `SEARCH_OP_PATH`, `~/.local/bin/op`,
`/opt/homebrew/bin/op`, `/usr/local/bin/op`, then the `PATH`. It uses op's own
configuration, so accounts already added (`op account list`) are simply there;
`SEARCH_OP_CONFIG_DIR` points op at another config folder for a test.

Open **Settings › Passwords › Password managers › 1Password** and pick a way in:

- **1Password app** (preferred; offered when `/Applications/1Password.app` or
  `~/Applications/1Password.app` exists). **Unlock with 1Password** runs `op
  signin`; the 1Password app shows its own Touch ID / approval sheet. No
  password ever enters Copper, and the authorization lasts as long as
  1Password's own rules say. If the app doesn't answer, the card says how to
  fix it: 1Password › Settings › Developer › **Integrate with 1Password CLI**
  (Touch ID unlock has to be on too), with an **Open 1Password** button.
- **Account password** (no app). Pick an account op already knows and type its
  password: `op signin --account <id> --raw`, the password on stdin. An
  account this Mac hasn't seen takes a sign-in address (default
  `my.1password.com`), email, Secret Key and password: `op account add --signin
  --raw`, the Secret Key through `OP_SECRET_KEY` and the password on stdin. The
  session token goes to every later `op` as `OP_SESSION_<user id>`. op ends a
  password session after 30 idle minutes; Copper runs a light `op whoami` every
  four minutes while unlocked, and when op says the session is over the card
  locks cleanly ("The 1Password session ended — unlock again") and the picker
  offers **Unlock 1Password…**.
- **Service account** (a Mac nobody sits at). Paste an `ops_…` token; it is
  used as `OP_SERVICE_ACCOUNT_TOKEN`. The card shows the vaults it can see.
  A token that may create items in no vault is read-only: the card says so and
  saves stay in the keychain.

**Security model.** No secret is ever an `op` argument (nothing shows in `ps`):
passwords go on stdin, the Secret Key and tokens through the child's
environment, item JSON for a save on stdin (`op item create -`, `op item edit ID` with the item JSON
piped in). Every `op` runs with a timeout, its stdin closed when nothing is
fed, and a child that outstays its timeout is killed. The session token (with
**Stay unlocked between launches**, on by default) and a service account token
are kept in 0600 files under Copper's support folder —
`<support>/1password/session` and `<support>/1password/service-account` —
never the keychain. Lock forgets the session and its file; Sign out also
forgets the token, the account and the mode. In app mode nothing is kept: at
launch Copper asks op whether the app still approves it.

**Data.** On unlock Copper lists the vaults and the item metadata (`op vault
list`, `op item list --categories Login,Password,Credit Card,Identity`) so the
picker fills at once ("Loading your 1Password vault…" until then), then reads
the items' details and secrets in the background in batches of 25 fed to `op
item get - --reveal` on stdin, a few batches at a time. They stay in memory
while unlocked and are dropped on lock; a pick that arrives before its batch
reads that one item. The list is read again every five minutes and on **Sync
now** (only changed items are read again). Logins map username/password by
field purpose, sites from the item's URLs, one-time codes from the OTP field
(computed locally by `TOTP.swift`), other fields as custom fields (hidden ones
treated like passwords); identities and credit cards feed the address and card
picker. Picker rows from 1Password carry a ① glyph; the footer names the
sources ("From 1Password", "From your keychain, Bitwarden and 1Password").

**Saves.** With 1Password chosen under *Save new passwords to*, a save offer
reads "Save to 1Password" — or "Update in 1Password" when the site already has
an item for that username, whose password is then changed in place (`op item
edit`) rather than a twin added. New logins are created in the vault chosen
under **New logins go to** (default Private / Personal / Employee, else the
first vault the account may create items in).

**Agents.** 1Password items share with agents exactly like Bitwarden ones (ids
`op:<item id>` in Agent access): a per-item toggle or share-everything, a vault
named `Agents` or a `copper-agent` tag allows, a `copper-agent: deny` field
always denies. `browser_sign_in`, `browser_autofill`, `copper signin|autofill`
and Jev's `SIGN_IN` / `AUTOFILL_*` fill in-process and return status only.

## Agent access

Open **Settings › Passwords › Agent access** to decide which saved accounts an
agent may use. The card exposes a share-everything switch and a per-account
toggle over the keychain + Bitwarden list. Sharing is off unless the user turns
on the broad switch, enables that account, or uses the Bitwarden convention:

- an item in a folder named `Agents` (case-insensitive) is allowed; and
- a custom field named `copper-agent` with value `deny` always denies that item,
  including when share-everything is enabled.

The per-account toggles stay in Copper and are not editable through MCP. The
broad switch can also be set by the owner from the shell or the headless Mac page
(`copper bitwarden policy --share folder|all`, loopback only; see above). See [Agents](agents.md) for `browser_sign_in`, `copper signin`, and Jev's
`SIGN_IN` control. Those operations fill in-process and return status only;
they do not return a password, TOTP code, or Bitwarden session key. Private
(`shy`) tabs are refused. With `--no-submit`, the secret remains in the page by
design, so do not immediately ask ordinary page-reading tools to inspect that
tab.

## Apple Passwords import

Apple's live Passwords AutoFill integration is closed to Copper: Apple's helper
has a kernel launch constraint that requires the Developer ID entitlement Copper
does not have. Import a copy instead:

1. Open the **Passwords** app.
2. Choose **File › Export All Passwords** and save Apple's CSV export.
3. In Copper, open **Settings › Passwords › Import and export › From a CSV
   file**, press **Choose File…** and pick that CSV.

The import goes into Copper's keychain backend. It is a one-time import, not a
live Apple Passwords connection; handle the exported CSV as sensitive data and
delete it when it is no longer needed.

## CSV in and out

**From a CSV file** takes the export of Chrome, Safari, Apple Passwords or a
password manager — any file whose first line names a website column (`url`,
`website`, `web site`, `web address`, `login_uri`, `site`, `address`, `login url`),
a username column (`username`, `user name`, `login_username`, `user`, `email`,
`email address`, `login`, `account`) and a password column (`password`, `login_password`), in any case and
order. Safari's and Apple Passwords' `Title,URL,Username,Password,Notes,OTPAuth`
and Chrome's `name,url,username,password,note` both qualify. UTF-8 with or
without a byte-order mark, UTF-16 and Latin-1 are read. The header is checked
before anything is saved, and the file is read off the main thread. One
sentence says what happened: "12 passwords imported", "12 passwords imported, 2
skipped (no site or no password)", "3 passwords imported — one-time codes aren't
kept", "That CSV has no password column — export it again as a passwords CSV",
"That file is empty", "Couldn't read that file as text — choose the .csv the
export made". Notes and one-time-code secrets in the file are not brought over.

The same module (`Fork/Credentials/PasswordCSV.swift`: `parse`, `columns`,
`summary`, `accounts`, `canonical`, `take(text:)`) reads the passwords file in Move in's Chrome and
Safari export paths, so every CSV says the same sentences.

**Export to a CSV file** asks for Touch ID (or the Mac's password), then where
to save, and writes every password Copper keeps in Chrome's columns (`name,
url, username, password, note`) — a file Copper and the other managers take
back. The file is created readable by this user only; the save panel says that
anyone who opens it can read every password in it. The Passwords panel
(Settings › Passwords › Open…) has the same **Export…** beside its imports.

Items in a connected password manager are not exported — they already live
there.

## Testing Copper's own passwords with `./bench passwords`

The keychain is never touched by automated tests. A named probe world can
instead keep Copper's own passwords and passkeys in a 0600 JSON file in its
folder (`probe-keychain.json`), set before launch:

```sh
defaults write com.officecommun.search.test.$W probe.keychain -string file
```

Only a named world with `bench` on honours it; Touch ID is answered by the
bench (`passwords prove yes|no`) instead of a sheet. Then:

```text
./bench passwords status | list | wipe
./bench passwords add HOST USER PW…          # as the save offer's Keep does
./bench passwords forget HOST [USER]
./bench passwords check HOST USER PW…        # {"matches": true|false}, never the secret
./bench passwords import CSV                 # the Choose File… path; status has the sentence
./bench passwords export CSV                 # {"written", "mode": "600", "sentence"}
./bench passwords csvcheck CSV               # the header check alone
./bench passwords prove yes|no               # Touch ID's answer
./bench passwords never [offer|add HOST…|forget HOST…|clear]   # offer = the save offer's Never here
```

Settings › Passwords › **Sites never asked** lists each site with its own
**Forget**; **Forget all** appears from four sites on.

## Testing with `./bench bw`

The bench backend is intended for isolated probe worlds, not the user's live
Copper session. Run the command with a world name when testing, for example
`./bench --world creds bw status`.

Available verbs are:

```text
./bench bw status
./bench bw server URL
./bench bw login EMAIL PASSWORD [OTP] [--method N]
./bench bw code OTP
./bench bw cancel
./bench bw unlock PASSWORD
./bench bw lock
./bench bw sync
./bench bw candidates HOST
./bench bw identities
./bench bw cards
./bench bw fields HOST
./bench bw usernames
./bench bw counts
./bench bw autofill card ID
./bench bw autofill identity ID
./bench bw share all on|off
./bench bw share bw:<item-id> on|off
```

`status` reports state, server, installation, the last error, `step` (what the
last `login` / `code` came to: `signedIn`, `needsCode:twoStep:1`,
`needsCode:newDevice`, `chooseMethod:0,1`, `failed`, `cancelled`) and
`pending` (the prompt `bw` is holding open, if any). `code` answers that
prompt. `./bench render bitwarden PATH` draws the Settings card on its own to
a PNG — no window comes forward — which is how the code step is looked at in a
headless probe world. `candidates`
returns stripped usernames and matching metadata; `share` changes Copper's
agent policy. Use placeholders in examples and avoid shell history or
transcripts containing credentials—never paste a real password, TOTP, or session
key into documentation or a report.

## Testing with `./bench op`

The same, for 1Password, in a probe world whose `SEARCH_OP_PATH` points at the
mock CLI in `docs/fixtures/op-mock/op` (python3; op 2.x's subcommands and JSON
shapes from a state file — `OP_MOCK_STATE`, default
`~/.config/op-mock/state.json` — seeded with two localhost logins (one with
a TOTP seed and two custom fields), one other login, an identity and a card
across a Private and a Shared vault; every call is appended to `calls.log`
beside the state, argv and env *names* only):

```sh
W=op1p; P=4211
mkdir -p /tmp/$W-mock /tmp/$W-fake/1Password.app     # a stand-in app path
defaults write com.officecommun.search.test.$W bench -bool true
defaults write com.officecommun.search.test.$W welcomed -bool true
open -n -g --stderr /tmp/copper-$W.log --env SEARCH_PROBE=$W --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT=$P --env SEARCH_OP_PATH="$PWD/docs/fixtures/op-mock/op" \
  --env OP_MOCK_STATE=/tmp/$W-mock/state.json \
  --env SEARCH_OP_APP_PATH=/tmp/$W-fake/1Password.app "$PWD/build/Copper.app"
(cd docs/fixtures && nohup python3 -m http.server 8765 --bind 127.0.0.1 </dev/null >/tmp/$W-http.log 2>&1 &)
```

`SEARCH_OP_APP_PATH=none` is a Mac without the app; `SEARCH_OP_PATH=none` a Mac
without the CLI. The mock's own switches (run it with the same
`OP_MOCK_STATE`): `op mock set app_integration on|off`, `op mock set
app_approve on|off` (the Touch ID sheet approved or dismissed), `op mock set
app_delay_ms N`, `op mock set latency_ms N` (every item call slow — the
loading state), `op mock expire` (every session ends), `op mock show` (items
with password fingerprints, never values), `op mock check TITLE USER PW`, `op
mock reset`. Seeded secrets: account password `correct horse battery staple`,
service tokens `ops_mockServiceTokenReadOnly0001` (Shared, read-only) and
`ops_mockServiceTokenWriter0002` (both vaults, writes to Shared); a second
account to add is `team.1password.com` / `new@example.com` / Secret Key
`A3-NEW123-ABCDEF-GHIJK-LMNOP-QRSTU-VWXYZ` / `new account password`. The mock
never blocks: it reads stdin only for the subcommands that take it, and gives
up on a pipe nobody writes to.

```text
./bench op status | accounts | counts
./bench op signin app [ACCOUNT]
./bench op signin password [--account A] PW…        # the rest of the line is the password
./bench op signin token TOKEN
./bench op account add ADDRESS EMAIL SECRETKEY PW…
./bench op unlock [PW…] | lock | signout | sync | keepalive
./bench op stay on|off | vault NAME | backend keychain|bitwarden|onepassword
./bench op candidates HOST | choose ID | rows | pick ROW | offer [keep|drop]
./bench op identities | cards | fields HOST | usernames
./bench op autofill card|identity ID
./bench op share all on|off | share op:<item-id> on|off
./bench render onepassword[-app|-password|-service|-dark] PATH
./bench render managers[-dark] PATH                     # the whole Password managers section
```

Long operations start and return; `status` says where they got to (`step`,
`lastError`, `problem`) and never holds a secret. `docs/fixtures/login.html` is
a sign-in form (it "signs in" by removing the form, the cue the save offer
waits for) with a one-time-code box and two custom-field boxes.
