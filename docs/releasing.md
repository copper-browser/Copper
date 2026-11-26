# Releasing and signing

*How a Copper release is built and signed, why the signature has to stay the same from one
release to the next, how development builds stay out of the installed Copper's way, and how to
renew the certificate. Files: `build.sh`, `release/package-app.sh`,
`release/designated-requirement.txt`, `release/copper-developer-id.cer`, `Copper.entitlements`,
`.github/workflows/release.yml`, `release/release-local.sh`, `Sources/Search/Fork/Signing.swift`,
`Sources/Search/Fork/Updates.swift`.*

## Cutting a release

```sh
gh workflow run release.yml -R copper-browser/Copper -f ref=fork                  # publish
gh workflow run release.yml -R copper-browser/Copper --ref <branch> -f publish=false   # dry run
gh workflow run release.yml -R copper-browser/Copper -f ref=fork -f runner=macos-15   # on a GitHub-hosted Mac
```

The workflow builds on Copper's own Mac, a self-hosted runner labelled `copper-mini`
(`COPPER_RELEASE=1 ./build.sh release app`), stamps
`<VERSION>.<YYYYMMDD>.<run>` into the bundle, signs it with Copper's Developer ID, has Apple
notarize it and staples the ticket, checks the signature and Gatekeeper's verdict on the zipped
bytes, launches the zipped app headless and asks `/health`
for its version, and then publishes the zip, its `.sha256`, `copper-version.json`,
`copper-install.sh` and the dSYM as a `v<version>` release. The updater, the curl installer and
the Homebrew tap all read that release.

**Block lists first** (once a release, on a Mac): `tools/shield/refresh.py`, then commit what
changed in `Sources/Search/Resources/shield`. It fetches EasyList, EasyPrivacy, uBlock's
filters, the cookie-notice lists and the regional lists and converts them for WebKit
(tools/shield/README.md); the app compiles each new version once, on first launch.

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

## Cutting a release without GitHub Actions

```sh
release/release-local.sh --preflight                  # the checks before the build, nothing more
release/release-local.sh --dry-run                    # build, sign, check, launch; publish nothing
release/release-local.sh                              # publish fork's HEAD as the next version
release/release-local.sh --version 1.0.20261111.106   # a version of your choosing
COPPER_RELEASE_REMOTE_DIR='~/farm/copper-release' release/release-local.sh   # build on the mini's internal disk
```

Exowatt's work stopped using GitHub Actions on 2026-11-09, and Roadrunner has no Mac to build
on yet, so a release can also be cut from Felipe's laptop: `release/release-local.sh` builds on
his Mac mini, signs on the laptop and publishes with `gh` as whoever is signed in (an owner of
`copper-browser`). The workflow above stays as it is for Collin's runner. Both make the same
release — the same build commands and checks, the same certificate and requirement, the same
assets, `copper-version.json` and release text — so the updater, the curl installer and the tap
can't tell which path cut one.

In the workflow's order:

1. **Preflight.** `HEAD` must be `fork`'s head on GitHub and the tree clean; a dry run says when
   it isn't and goes on, since it builds the commit (`git archive`), never the working tree. The
   version is `<VERSION>.<UTC YYYYMMDD>.<n>`, `n` one more than the highest trailing number of
   any `v…` tag or release in the repository, so it never takes a number the workflow used or
   sorts below one. `--version` picks it instead; it must be new, and to publish, above the
   latest. The Developer ID `.p12`, its password and the notary key must be in
   `~/.config/copper-developer-id`, mode 0600 (*How a release is signed*), and the `.p12` must hold
   `release/copper-developer-id.cer`.
2. **Build on the mini** (`felipe-exowatt@100.112.175.26`, over Tailscale). The commit's tree
   goes to a job folder on its external disk, `/Volumes/Farm/farm-exowatt/copper-release/`, or
   wherever `COPPER_RELEASE_REMOTE_DIR` says (quoted, `~/` is the mini's home: the internal disk
   when the external one is full). The run wants 5 GB free there and stops before building
   without it: the build compiles three configurations (arm64 release, the debug build
   `swift test` needs, x86_64 release), each about 1 GB of `.build` on the mini, plus the sources
   and the two apps with their dSYMs, about 3.5 GB in all; every run prints what it used. Then
   the workflow's build steps run there with their assertions:
   `COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY= ./build.sh release app`, `swift test --filter xosInsert`
   and the Intel cross-build. With `SEARCH_SIGN_IDENTITY` empty, `build.sh` asks the keychain for
   a Developer ID; here it is handed a `security` that finds nothing, so the build is ad hoc as on
   the runner and no keychain is touched on either Mac. The two unsigned apps and their dSYMs come
   back to the laptop, and the sources and build products on the mini are deleted at once.
3. **Sign on the laptop** with [rcodesign](https://github.com/indygreg/apple-platform-rs)
   (apple-codesign 0.29.0, the `macos-universal` build, pinned by SHA-256 and fetched once into
   `~/.cache/copper-release/`). It reads the `.p12` and `p12-password` where they are
   (`--p12-file`, `--p12-password-file`): no keychain, and the key is never copied, printed or
   sent anywhere. The rest is `package-app.sh`'s: stamp the version into `Info.plist`, refuse a
   bundle that isn't `com.collinrijock.copper` or doesn't pin the team, and sign with the
   hardened runtime, `Copper.entitlements`, Apple's timestamp and the explicit requirement
   (compiled with `csreq -r release/designated-requirement.txt -b …`, which is the form rcodesign
   takes). Then `xcrun notarytool submit --wait` with `AuthKey_<id>.p8` and `notary-issuer`, the
   ticket stapled and the zip made again, as on the runner.
   build.sh's ad-hoc signature is removed first, because rcodesign carries an existing
   signature's flags and entitlements over. `--exclude 'Contents/Resources/**'` keeps rcodesign
   from signing the SwiftPM resource bundle in `Resources` as a bundle of its own; codesign's
   rules treat `Resources` as data, and the bundle's files are sealed one by one, as before.
4. **Check, package, launch.** The workflow's *Check the signature* on the zipped bytes (plus: the
   hardened runtime and no other flag, signed by a Developer ID of the team); the versioned and stable zips and
   their `.sha256`s; the dSYMs; `copper-version.json`, written by the workflow's own code and
   held to the fields of the manifest `releases/latest` serves; `copper-install.sh`. The zips are
   `ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent`: the laptop gives every file a
   `com.apple.provenance` attribute, which plain `ditto` stores as `._` files that a plain
   `unzip` would leave inside the bundle, unsealed. The runner's zips have none, and neither do
   these. Then both zips are opened headless on the mini, in throwaway worlds on free ports, and
   `/health` must report the version within 90 s (the Intel app under Rosetta, 120 s). An app
   has to start in the session of whoever is logged in there: `open` over ssh has no window
   server (LaunchServices answers -10810) and `launchctl asuser` needs root, so a one-shot agent
   in that session's launchd domain (`launchctl bootstrap gui/<uid>`) runs the `open`. That
   session may not read the external disk, so the two apps are unzipped into the user's
   temporary folder on the internal one. Only those pids are stopped; the apps, the worlds'
   folders and defaults, and the WebKit and cache folders the check created are deleted.
5. **Publish** (not in a dry run): the tag is checked once more (a workflow run may have taken the
   number during the build), then `gh release create v<version> --target <commit> --latest` with
   every asset and the workflow's release text, and the published bytes are checked — the
   versioned zips, and the stable zips and manifest behind `releases/latest/download`.

Everything lands in `build/release-local/<version>/` (gitignored): `assets/` is exactly what a
release uploads, `release-notes.md` its text, `logs/` the mini's build and launch output and
rcodesign's. The job folder on the mini is deleted at the end, whatever happened.

**What differs from a workflow release.** Only the signer. The requirement, the flags (the
hardened runtime), the entitlements,
the sealed resources (the same `CodeResources`), the certificate and the signed attributes are
the same, and `codesign` verifies both the same way. rcodesign hashes code in 4 KB pages where
codesign uses 16 KB for arm64 (x86_64 is 4 KB in both), so the arm64 signature is about
140 KB instead of 36. That is not part of the designated requirement: macOS keeps a person's
grants and an installed Copper's updater accepts the bundle exactly as it does a workflow
release (`codesign --verify --deep --strict -R=…`), and the kernel checks 4 KB pages on Apple
silicon as it does on Intel. (Notarizing an rcodesign signature is rcodesign's documented use.)
The first dry run was rehearsed against the real thing: Copper
1.0.20261110.104 as released, headless in a test world pointed at a stub feed, staged the
rcodesign-signed 1.0.20261110.105 and passed the pre-swap check (`updates dry-run on`, then
`updates upgrade`).

**One sequence of numbers.** The workflow's `n` is its run number. A workflow run on the same
UTC day as a local release can land on the number the local one took; its *Create the GitHub
release* step then fails on the existing release and publishes nothing. Run it again, or cut
the release here.

## How a release is signed

- **The certificate.** A **Developer ID Application** certificate of Copper's Apple Developer
  team: `Developer ID Application: Collin Rijock (95X7XYUVNX)`, issued by Apple's *Developer ID
  Certification Authority* (G2 Sub-CA), valid 2026-11-25 → 2027-12-25. The public half is
  `release/copper-developer-id.cer`; its SHA-1 is `d6852ec5c7b2cad290909e6414fb66a9b7678e72`.
  Only the team's Account Holder can make one, on developer.apple.com (the App Store Connect
  API answers *"can only be performed by the Account Holder"*); the API can fetch it once it
  exists (`GET /v1/certificates`).
- **The keys** exist in two places: Copper's Mac mini, `~/.config/copper-developer-id/` (0600:
  `devid.key` and its CSR, `copper-developer-id.p12` (the key and the certificate only:
  rcodesign takes the first certificate in a p12 as the signer, so Apple's intermediate is not
  in it), `p12-password`, and the notary key `AuthKey_<key id>.p8` with `notary-issuer`), and the
  repository secrets `COPPER_DEVELOPER_ID_P12_BASE64` / `COPPER_DEVELOPER_ID_P12_PASSWORD`,
  `COPPER_NOTARY_KEY_BASE64` / `COPPER_NOTARY_KEY_ID` / `COPPER_NOTARY_ISSUER`. The notary key is
  an App Store Connect team key, *Copper notarize*, with the Developer role (the least
  notarytool takes) and nothing else. Neither is ever in the repository.
- **On the runner.** *Signing keychain and notary key* decodes the p12 into a keychain made for
  that run (random password, on the search list only for the run) and the notary key into the
  run's temporary folder, adds Apple's *Developer ID G2* intermediate (`release/DeveloperIDG2CA.cer`;
  macOS ships only the G1 one, and codesign needs the chain), checks that the certificate in the
  p12 is the one `release/` holds and
  that the requirement names its team, and *Delete the signing keychain and notary key* removes
  both again (`if: always()`).
- **The requirement.** `release/package-app.sh` signs with the certificate's SHA-1 and an
  explicit designated requirement, the one line in `release/designated-requirement.txt`:

  ```
  designated => identifier "com.collinrijock.copper" and anchor apple generic
    and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]
    and certificate leaf[subject.OU] = "95X7XYUVNX"
  ```

  That is the requirement Apple's tools give a Developer ID app: Copper's identifier and *any*
  Developer ID Application certificate Apple issued to the team, so renewing the certificate
  changes nothing for macOS or the updater (`Signing.releaseRequirement`).
- **The flags.** The hardened runtime (`--options runtime`), Apple's secure timestamp and the
  entitlements in `Copper.entitlements` — what the runtime would otherwise refuse: the camera,
  the microphone, calendars, location (pages ask for these) and Apple Events (links handed to
  the running Copper, `Fork/LinkRelay.swift`). WebKit's JIT runs in WebKit's own processes, so
  the app needs no JIT entitlement. It signs inside-out (`--deep` with the identity, then the
  app itself with the entitlements and `-r`). It refuses to sign a bundle whose id is not
  `com.collinrijock.copper`, or whose binary does not pin the same team
  (`Signing.developerIDRequirement`), or without the notary key.
- **Notarized and stapled.** Each zip goes to Apple's notary service
  (`xcrun notarytool submit --wait`, a few minutes); on *Accepted* the ticket is stapled to the
  app (`xcrun stapler staple`) and the zip made again around it, so Gatekeeper opens a download
  offline too. On anything else the run prints Apple's log (`notarytool log`) and stops. No
  installer, cask or page clears the quarantine flag any more.
- **The checks** (*Check the signature*): `codesign -dr -` must print exactly that requirement
  (Apple's `/* exists */` comments aside); `codesign --verify --deep --strict`, the same with
  `-R="<requirement>"` (what Copper checks from now on) and with the bridge's requirement (what
  the last self-signed releases check) must pass; the hardened runtime and a secure timestamp
  must be there and the entitlements must be `Copper.entitlements`; `xcrun stapler validate`
  must pass and `spctl -a -vvv -t exec` must say `accepted` and `source=Notarized Developer ID`.

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
isn't signed by a Developer ID of Copper's team as `com.collinrijock.copper` is refused with *"Copper X isn't
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

### The move to Developer ID

Releases moved from Copper's own self-signed certificate (`CN=Copper Release Signing`, SHA-1
`76264b1f74fbc16100eb71c855edd6d4165c4fbe`, secrets `COPPER_SIGNING_P12_BASE64` /
`COPPER_SIGNING_P12_PASSWORD`) to the Developer ID, notarized, as a certificate rotation in two
releases:

1. **The bridge**, still signed with the old certificate, whose updater accepts either:

   ```
   identifier "com.collinrijock.copper" and (certificate leaf = H"76264b1f74fbc16100eb71c855edd6d4165c4fbe"
     or (anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]
         and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "95X7XYUVNX"))
   ```

2. **The switch**: the first release signed with the Developer ID, notarized and stapled. A
   Copper from before the bridge refuses it (*"isn't signed with Copper's release
   certificate"*) and its person reinstalls once (curl installer, Homebrew or the zip).

The switch changes the DR (from the old certificate to the team), so its grants go one last
time, as with the first signed release: turn Copper on again in System Settings › Privacy &
Security › Full Disk Access and Files & Folders, and click Always Allow once more if the
keychain asks. After that they stay, through certificate renewals too.

## Development builds have their own identity

`./build.sh` without `COPPER_RELEASE=1` (and without the `dmg`/`ship` steps) builds
**`com.collinrijock.copper.dev`**:

- its own TCC records, defaults domain, WebKit data container (`~/Library/WebKit/com.collinrijock.copper.dev`)
  and keychain identity — a worktree build can no longer overwrite the installed Copper's grants
  or share its cookies;
- always a test world (`Store.testing`): `SEARCH_PROBE=<name>` picks the world as before
  (`~/Library/Application Support/Copper (<name>)`, defaults suite
  `com.collinrijock.copper.test.<name>`); started with no world at all — a double-click, a plain
  `open build/Copper.app` — it is the world **dev**, `Copper (dev)`, suite
  `com.collinrijock.copper.test.dev`. It never opens `~/Library/Application Support/Copper`.
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

## Renewing the certificate

The Developer ID expires on 2027-12-25. Renew it before then (Apple allows a few Developer ID
certificates per team at once, so the old one keeps signing until the new one is in place).
Because the requirement names the team, not the certificate, a renewal needs no bridge and costs
nobody a re-grant; a signature made before the expiry stays valid after it, thanks to the secure
timestamp.

1. On Copper's Mac mini, a new key and CSR (openssl only, no keychain):

   ```sh
   umask 077; cd ~/.config/copper-developer-id
   /usr/bin/openssl genrsa -out devid.key 2048
   /usr/bin/openssl req -new -key devid.key -subj "/CN=Copper Developer ID/C=US" -out devid.csr
   ```

2. The Account Holder (Collin) signs in at developer.apple.com › Certificates › + ›
   **Developer ID Application** › G2 Sub-CA and uploads `devid.csr`. The `.cer` can then be
   fetched with the App Store Connect API (`GET /v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION_G2`,
   `certificateContent` is the DER, base64).
3. The p12: the key and the certificate, nothing else (rcodesign signs with the first certificate
   in it; Apple's intermediate is `release/DeveloperIDG2CA.cer`):

   ```sh
   /usr/bin/openssl x509 -inform der -in devid.cer -out devid.pem
   /usr/bin/openssl rand -base64 60 | tr -dc 'A-Za-z0-9' | head -c 40 > p12-password
   /usr/bin/openssl pkcs12 -export -inkey devid.key -in devid.pem \
     -name "Developer ID Application: Collin Rijock (95X7XYUVNX)" -out copper-developer-id.p12 \
     -passout file:p12-password -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1   # what `security import` reads
   ```

4. In one commit, the new `devid.cer` as `release/copper-developer-id.cer` (the SHA-1 above in this
   page too); then the secrets:
   `base64 -i copper-developer-id.p12 | tr -d '\n' | gh secret set COPPER_DEVELOPER_ID_P12_BASE64 -R copper-browser/Copper`
   and `gh secret set COPPER_DEVELOPER_ID_P12_PASSWORD -R copper-browser/Copper < p12-password`,
   and the same pair in `~/.config/copper-developer-id` wherever `release/release-local.sh` runs.
   *Signing keychain and notary key* fails the run if the secret and `release/` disagree; the
   local path fails its preflight.
5. A dry run (`-f publish=false`, or `release/release-local.sh --dry-run`) must sign, notarize and
   pass every check before the next real release.

The notary key doesn't expire; revoke and replace it (App Store Connect › Users and Access ›
Integrations › Team Keys, role Developer) if it leaks, then `COPPER_NOTARY_KEY_BASE64` (the
`.p8`, base64), `COPPER_NOTARY_KEY_ID` and the local `AuthKey_<id>.p8`.

**Another team** (Copper moving to a company's account) is a new requirement: that is a rotation
like the move to Developer ID above — a bridge release whose updater accepts both teams, then the
switch.

### Keeping the key

The `.p12`, its password and the notary key are kept together on Copper's Mac mini and offline,
beside the repository secrets; the secrets alone can't be read back out of GitHub. If the
Developer ID key is lost, renew (above): the requirement names the team, so nothing else
changes. If it leaks, renew at once and ask Apple Developer Support to revoke the old
certificate; they set the revocation date, so copies signed before the leak keep opening.
