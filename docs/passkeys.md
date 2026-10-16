# Passkeys in Copper

Copper is its own WebAuthn authenticator in builds that do not have Apple's
`com.apple.developer.web-browser.public-key-credential` entitlement. A small
page-side WebAuthn polyfill presents the normal `PublicKeyCredential` API. Its
create and get requests cross a reply-capable WebKit message bridge; Copper
validates the relying-party id, asks for Touch ID (or the Mac login password),
and signs with a P-256 key kept in the login keychain under **Copper Passkeys**.

The page bridge uses `publicKey.rp.id` when creating a passkey and
`publicKey.rpId` when signing in. If the site omits that field, the document
hostname is the default. An explicit parent-domain id is preserved: a page at
`accounts.example.test` can ask for its `example.test` credential, subject to
Copper's existing native origin/RP validation. Previously creation sent the
whole `rp` object and assertion ignored `rpId`, causing the native side to fall
back to the sign-in subdomain and miss credentials scoped to the parent.

New credentials use ES256, the platform attachment, and the standard WebAuthn
client-data and authenticator-data shapes. `getTransports()` reports only
`internal`; this authenticator does not support `hybrid`. The Settings › Passwords
page lists the site, account, source, and use dates. **Forget** proves the user first and
then removes the keychain item.

## What Copper can and cannot do

- Copper makes a new passkey on each site. It cannot use an existing iCloud
  Keychain passkey because WebKit does not hand that credential to an
  unentitled browser.
- Passkeys imported from Chrome through Flow can be stored and used by Copper
  when their private key is available to the import path.
- Keys are local to this Copper installation and its keychain. There is no
  cross-device sync, Bluetooth/hybrid hand-off, or iCloud sync in this build.
- Conditional (autofill) mediation works for sign-in. A site that calls
  `navigator.credentials.get({mediation: 'conditional'})` waits while Copper
  lists that site's passkeys first in the account list under its name or
  password box, beside the saved passwords. Picking one asks for Touch ID and
  answers the waiting request; nothing is signed until you pick. A newer
  conditional request replaces the older one, an abort or leaving the page
  lets it go, and the rows show only while the tab is still on the host that
  asked. Conditional *creation* is still refused. A normal create/get ceremony
  always asks for user verification.
- The authenticator supports ES256 (COSE algorithm `-7`) and discoverable
  credentials. Other algorithms are rejected rather than silently producing a
  credential a site cannot verify.

## Regression checks

```sh
node --test docs/fixtures/passkey-bridge-test.cjs
```

This runs the production page script extracted from its Swift raw string in an
isolated JavaScript context. It covers parent-domain create/get, host defaults,
operation-specific RP fields, option immutability, native error propagation,
transport reporting, non-WebAuthn fallbacks, cancellation, conditional mediation,
and a missing bridge. It uses only synthetic data, a mock message handler and
Node's built-in test runner: no account, network, browser profile or keychain.
It does not prove a successful live Google login or native signature verification.

```sh
# Build/package the dev app and run the native smoke test:
docs/fixtures/passkey-native-e2e.sh
# Or reuse an already-built dev app:
COPPER_SKIP_BUILD=1 docs/fixtures/passkey-native-e2e.sh
```

The native fixture uses real WebKit, the Swift relay and a localhost server in
a fresh headless test world. It creates one synthetic keychain item scoped to
that world, signs an assertion, verifies its ES256 signature with WebCrypto,
checks the RP hash/user-verification flag, rejects unrelated RP ids for both
create and get, and checks internal-only transport. It then forgets the item
and verifies the count is zero; its exit trap cleans the scoped service and
test-world files on failure as well. It never replaces the installed Copper
app or uses real credentials. Approval is automated **only** in the test world;
a successful run does not validate a real Touch ID prompt or live Google login.

For automated QA, `./bench --world pkqa passkeys answer yes` answers the native
verification prompt in that isolated test world. `list`, `count`, and
`forget --id ID` expose metadata only; private key bytes are never returned.
