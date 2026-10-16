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

## Passkey extensions (1Password and others)

An extension such as 1Password intercepts WebAuthn from a MAIN-world content
script (`inline/injected/webauthn-listeners.js`). At load it binds the
current `navigator.credentials.get`/`create` as its fallback, captures the
current `PublicKeyCredential` statics, then installs non-configurable
accessors. Each call asks its background whether to handle the request
(signed in, a matching passkey, the user's save/fill settings); if not, or if
the user chooses "use another method", it calls the bound fallback.

WebKit injects extension content scripts before the tab's own user scripts,
so that fallback used to be WebKit's unentitled implementation, which rejects
every request at once (`NotAllowedError: The request is not allowed by the
user agent…`). Copper's polyfill then replaced `window.PublicKeyCredential`,
dropping the extension's conditional-mediation hooks as well.

Copper therefore carries its authenticator inside the extension:
`ExtensionShims.prepare` writes `search-passkeys.js` (`Passkeys.extensionPrelude`)
and runs it right after `search-shim.js` in every `world: MAIN` content
script. It is inert unless the tab registered the `copperPasskeys` handler,
which happens exactly while Copper is the authenticator. The order is then:

1. Copper installs its `navigator.credentials` methods and statics on WebKit's
   own `PublicKeyCredential` (kept, not replaced).
2. The extension wraps them. When it handles a request, Copper is never asked;
   when it declines, its fallback is Copper's authenticator.
3. Copper's deferred reinstall restores only a method that reverted to WebKit's
   native one, never a wrapper installed after it.

If an extension's hook still lands first (a script injected dynamically, not
from the manifest), Copper leaves it in place; if the hook is an accessor with
a setter (1Password's), Copper is offered through that setter, which the hook
uses whenever it is not intercepting.

Credentials Copper returns, and ones an extension builds with
`Object.setPrototypeOf(…, PublicKeyCredential.prototype)`, are instances of
WebKit's `PublicKeyCredential`, `AuthenticatorAssertionResponse` /
`AuthenticatorAttestationResponse` and `AuthenticatorResponse`, with
`getClientExtensionResults()` and `toJSON()`. A page without those classes gets
stand-ins of the same names.

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
  asked. Conditional *creation* is still refused. When an extension that
  offers passkey autofill (1Password) hooks the API, its answer is what the
  page sees; a request it passes on reaches Copper's list. A normal
  create/get ceremony always asks for user verification.
- With no credential for the relying party, `get` rejects with
  `NotAllowedError`, the same answer a platform authenticator gives when the
  user has nothing to pick; sites treat it as a cancel and offer another way.
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
a missing bridge, and the extension order: a 1Password-shaped hook installed
after Copper (declines → Copper answers, accepts → Copper not asked), one
installed before it (left in place, offered Copper through its setter), the
deferred reinstall never undoing a later wrapper, and the instance/JSON shapes. It uses only synthetic data, a mock message handler and
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

```sh
# A synthetic MV3 extension whose MAIN-world script wraps WebAuthn like 1Password:
COPPER_SKIP_BUILD=1 docs/fixtures/passkey-extension-e2e.sh
```

The extension fixture installs that extension into a fresh headless test world
and opens a localhost relying party. It checks that Copper's authenticator was
in place before the extension's hook ran, that the extension's
`isConditionalMediationAvailable` hook survives, that get/create the
extension accepts never reach Copper (the scoped keychain stays empty), that
declined get/create fall through to Copper and return `PublicKeyCredential` /
`Authenticator*Response` instances, and that a missing credential is a
`NotAllowedError`. It cleans up like the native fixture. It uses no real
extension, so it does not prove 1Password's own background decisions or a
live Google sign-in.

For automated QA, `./bench --world pkqa passkeys answer yes` answers the native
verification prompt in that isolated test world. `list`, `count`, and
`forget --id ID` expose metadata only; private key bytes are never returned.
