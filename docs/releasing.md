# Releasing and signing

*How a Copper release is built and signed, why the signature has to stay the same from one
release to the next, how development builds stay out of the installed Copper's way, and how to
rotate the certificate. Files: `build.sh`, `release/package-app.sh`,
`release/designated-requirement.txt`, `release/copper-release-signing.cer`,
`.github/workflows/release.yml`, `Sources/Search/Fork/Signing.swift`,
`Sources/Search/Fork/Updates.swift`.*

## Cutting a release

```sh
gh workflow run release.yml -R copper-browser/Copper -f ref=fork                  # publish
gh workflow run release.yml -R copper-browser/Copper --ref <branch> -f publish=false   # dry run
gh workflow run release.yml -R copper-browser/Copper -f ref=fork -f runner=macos-15   # on a GitHub-hosted Mac
```

The workflow builds on Copper's own Mac, a self-hosted runner labelled `copper-mini`
(`COPPER_RELEASE=1 ./build.sh release app`), stamps
`<VERSION>.<YYYYMMDD>.<run>` into the bundle, signs it with Copper's release certificate,
checks the signature on the zipped bytes, launches the zipped app headless and asks `/health`
for its version, and then publishes the zip, its `.sha256`, `copper-version.json`,
`copper-install.sh` and the dSYM as a `v<version>` release. The updater, the curl installer and
the Homebrew tap all read that release.

**Two CPUs.** Every release is built twice on the same Apple Silicon runner: natively for
`arm64`, and cross-built for Intel with `COPPER_ARCH=x86_64 ./build.sh release app`
(`swift build --triple x86_64-apple-macosx14.0`, into `build/x86_64/Copper.app`). Both are
stamped and signed the same way (`release/package-app.sh … <arch>`, which refuses a binary that
isn't that CPU), both are checked, and both are launched — the Intel one through Rosetta, when
the runner has it (`softwareupdate --install-rosetta --agree-to-license`; without it the run
warns and skips only that launch). Each CPU gets `copper-<version>-macos-<arch>.zip`, its stable
`copper-macos-<arch>.zip` name, the `.sha256`s and a dSYM. `copper-version.json` lists both under
`archives`; its top-level `zip`, `sha256` and `archiveUrl` stay arm64's, which is all a Copper
from before the Intel build reads. The updater (`Fork/Updates.swift`) takes its own CPU's archive
— an Intel Copper never falls back to the arm64 one — and checks the unpacked bundle's
architecture before the swap. The curl installer picks by `uname -m` (arm64 under a Rosetta
shell), and the tap's cask switches with Homebrew's `arch` stanza.

**`publish=false`** is a dry run: everything up to and including the launch check, then the zip,
its `.sha256`, `copper-version.json` and the dSYM are kept as the run's artifact (7 days) and
nothing else happens — no tag, no GitHub release, no asset upload, nothing the updater,
installer or tap reads. Only the *Create the GitHub release* step is handed a token
(`GH_TOKEN`; checkout keeps no credentials), and it and *Verify the published bytes* run only
when publish is exactly `true`.
`ref` defaults to the branch the run was started from (`fork` from the Actions page). A
publishing run refuses any ref but `fork`; dry runs build any ref.

**`runner`** picks the Mac. `copper-mini` (the default) is Copper's own, always-on Mac with
Xcode, registered to this repository as a self-hosted runner; it picks a run up at once.
`macos-15` is a GitHub-hosted Mac, for when that Mac is offline (the run would otherwise wait
in the queue). Hosted macOS arm64 runners are often short: a job nobody picks up is cancelled
after 15 minutes with *not acquired by Runner of type hosted* and no steps run. Because the
repository is public, workflows from outside contributors' pull requests wait for a
maintainer's approval (Settings › Actions › Fork pull request workflows), and only
`release.yml` names the `copper-mini` label.

## How a release is signed

- **The certificate.** One self-signed code-signing certificate, `CN=Copper Release Signing`
  (RSA 3072, SHA-256, `extendedKeyUsage=codeSigning`, valid 2026-10-07 → 2036-10-04). The
  public half is `release/copper-release-signing.cer`; its SHA-1 is
  `76264b1f74fbc16100eb71c855edd6d4165c4fbe`. It is not a Developer ID and the app is not
  notarized, so the installer and the cask still clear the quarantine flag (`xattr -cr`).
- **The private key** exists in two places: the repository secrets
  `COPPER_SIGNING_P12_BASE64` (the password-protected `.p12`, base64) and
  `COPPER_SIGNING_P12_PASSWORD`, and Felipe's offline copy. It is never in the repository.
- **On the runner.** *Signing keychain* decodes the p12 into a keychain made for that run
  (random password, on the search list only for the run), checks that the certificate in it is
  the one `release/` names, and *Delete the signing keychain* removes it again (`if: always()`).
- **The requirement.** `release/package-app.sh` signs with the certificate's SHA-1 and an
  explicit designated requirement, the one line in `release/designated-requirement.txt`:

  ```
  designated => identifier "com.collinrijock.copper" and certificate leaf = H"76264b1f74fbc16100eb71c855edd6d4165c4fbe"
  ```

  It signs inside-out (`--deep` with the identity, then the app itself with `-r`), no hardened
  runtime, no entitlements, no timestamp — the flags the ad-hoc releases had, so WebKit, its JIT
  and the extensions run exactly as before. It refuses to sign a bundle whose id is not
  `com.collinrijock.copper`, or whose binary does not pin the same certificate
  (`Signing.releaseCertificate`).
- **The checks** (*Check the signature*): `codesign -dr -` must print exactly that requirement;
  `codesign --verify --deep --strict` (what an older Copper checks) and
  `codesign --verify --deep --strict -R="<requirement>"` (what Copper checks from now on) must
  pass; there must be no entitlements.

Check any copy by hand:

```sh
codesign -dr - /Applications/Copper.app
codesign --verify --deep --strict -R="$(cat release/designated-requirement.txt)" /Applications/Copper.app
```

(`-R="identifier …"` reaches codesign as `=identifier …`: the leading `=` makes it requirement
text, not a file name. Don't write `-R='=…'` — that is two of them, and a syntax error.)

## Why the requirement matters

macOS remembers what a person allowed an app to do against the app's **designated requirement**
(DR): Full Disk Access, Files & Folders (including another app's data, like Chrome's),
Automation, Screen Recording, Accessibility, and each keychain item's "Always Allow". When the app
asks again, macOS checks the running code against the requirement it stored.

An ad-hoc signature has no certificate, so its DR is `cdhash H"…"` — the hash of that one build.
Every update was a new hash, and macOS treated it as a different app: grants silently stopped
applying (tccd logs `Failed to match existing code requirement`) and the keychain asked again.
That is why Move in could not read Chrome after an update even though Copper was switched on in
System Settings (the whole story: [plans/2026-10-07-move-in-and-settings.md](plans/2026-10-07-move-in-and-settings.md)).

With the explicit requirement every release satisfies the same DR, so a grant made once keeps
working through updates. The updater also holds every download to it
(`Signing.unsatisfied`, in `Updates.fetchAndStage` and again just before the swap): a bundle that
isn't signed by this certificate as `com.collinrijock.copper` is refused with *"Copper X isn't
signed with Copper's release certificate, so it won't replace this one."* A development build or
a test copy is held to its own identifier instead (it has no certificate to pin);
`./bench --world W updates requirement TEXT|off` points a test world at another requirement.

### The first signed release

**1.0.20261007.42** (#46) is the first release signed with the certificate; 1.0.20261007.38 is
the last ad-hoc one. 1.0.20261008.46 is the first update from one signed release to another,
and the first that keeps every grant.

The last ad-hoc Copper updates to the first signed one through its own, older checks: the
feed's SHA-256, the bundle id (`com.collinrijock.copper`, unchanged), the version and
`codesign --verify --deep --strict` — integrity only, which a certificate-signed bundle passes
(the workflow runs that exact command on every release). From then on, Copper also checks the
requirement.

That one update still changes the DR (from a cdhash to the certificate), so its grants go one
last time: after it, turn Copper on again in System Settings › Privacy & Security › Full Disk
Access and Files & Folders, and click Always Allow once more if the keychain asks. After that,
they stay.

## Development builds have their own identity

`./build.sh` without `COPPER_RELEASE=1` (and without the `dmg`/`ship` steps) builds
**`com.collinrijock.copper.dev`**:

- its own TCC records, defaults domain, WebKit data container (`~/Library/WebKit/com.collinrijock.copper.dev`)
  and keychain identity — a worktree build can no longer overwrite the installed Copper's grants
  or share its cookies;
- always a test world (`Store.testing`): `SEARCH_PROBE=<name>` picks the world as before
  (`~/Library/Application Support/Copper (<name>)`, defaults suite
  `com.officecommun.search.test.<name>`); started with no world at all — a double-click, a plain
  `open build/Copper.app` — it is the world **dev**, `Copper (dev)`, suite
  `com.officecommun.search.test.dev`. It never opens `~/Library/Application Support/Copper`.
  Drive it with `./bench --world dev …`; plain `./bench` talks to the installed Copper;
- no `copper://` URL scheme, so canvas links clicked in another app always reach the installed
  Copper;
- ad hoc as before (`SEARCH_SIGN_IDENTITY=-` skips the keychain lookup), so each rebuild is a
  new DR for `.dev` — re-grant a dev build if a test needs a real grant;
- its updater is quiet on the real feed (test worlds never stage releases) and, with a stub feed,
  accepts only `.dev` bundles.

A local build that should *be* Copper (rare: only to try the release packaging) is
`COPPER_RELEASE=1 ./build.sh release app`, then `release/package-app.sh` (ad hoc without
`COPPER_SIGN_IDENTITY`).

## Rotating the certificate

The certificate is good until 2036-10-04. Replace it before then, or at once if the key leaks.
A new certificate is a new DR, so the release that switches costs everyone one re-grant, like the
first signed release did.

1. On a trusted Mac, with openssl only (no keychain needed):

   ```sh
   umask 077; mkdir -p ~/.config/copper-signing && cd ~/.config/copper-signing
   # openssl.cnf: CN = Copper Release Signing; basicConstraints = critical, CA:FALSE;
   # keyUsage = critical, digitalSignature; extendedKeyUsage = critical, codeSigning
   /usr/bin/openssl genrsa -out release.key 3072
   /usr/bin/openssl req -new -x509 -config openssl.cnf -key release.key -sha256 -days 3650 -out release.pem
   /usr/bin/openssl x509 -in release.pem -outform DER -out copper-release-signing.cer
   /usr/bin/openssl rand -base64 60 | tr -dc 'A-Za-z0-9' | head -c 40 > p12-password
   /usr/bin/openssl pkcs12 -export -inkey release.key -in release.pem -name "Copper Release Signing" \
     -out copper-release-signing.p12 -passout file:p12-password \
     -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1   # what `security import` reads
   rm release.key; shasum -a 1 copper-release-signing.cer
   ```

2. **Bridge release, still signed with the old certificate.** A Copper already installed
   refuses any update that isn't signed with the certificate it pins, so first ship one release
   whose updater accepts both: `Signing.releaseRequirement` becomes
   `identifier "com.collinrijock.copper" and (certificate leaf = H"<old>" or certificate leaf = H"<new>")`.
   `release/` and the secrets stay on the old certificate. The same commit relaxes
   `SigningTests.theUpdaterPinsTheCertificateInRelease`: it expects the single-leaf text of
   `release/designated-requirement.txt`, and the Swift requirement is now the two-leaf `or`.
   Let it reach people (a few days).
3. **The switch.** In one commit: the new `.cer` in `release/`, the new SHA-1 in
   `release/designated-requirement.txt` and `Signing.releaseCertificate` (the requirement back to
   the single new leaf), then the secrets:
   `base64 -i copper-release-signing.p12 | tr -d '\n' | gh secret set COPPER_SIGNING_P12_BASE64 -R copper-browser/Copper`
   and `gh secret set COPPER_SIGNING_P12_PASSWORD -R copper-browser/Copper < p12-password`.
   *Signing keychain* fails the run if the secret and `release/` disagree.
4. A dry run (`-f publish=false`) must show the new requirement on the artifact before the first
   real release. Anyone who skipped the bridge release reinstalls once (curl installer or
   Homebrew).

### Keeping the key

The bridge in step 2 needs the old key: only a release signed with it can teach installed
Coppers to accept a new certificate. So the `.p12` and its password are kept together, offline,
outside any repository, beside the repository secrets; the secrets alone can't be read back out
of GitHub. After a rotation, the new `.p12` and password replace the offline copy, and the
working folder (`~/.config/copper-signing`) is emptied.

If the key is lost (or leaks and must not sign again), there is no bridge: ship the switch
(step 3) directly, and every installed Copper refuses it with *"isn't signed with Copper's
release certificate"* and the download link. Everyone reinstalls once from the release page,
the curl installer or the cask, and grants Copper's permissions again.
