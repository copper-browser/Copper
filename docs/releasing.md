# Releasing and signing

*How a Copper release is built and signed, why the signature has to stay the same from one
release to the next, how development builds stay out of the installed Copper's way, and how to
renew the certificate. Files: `build.sh`, `release/package-app.sh`,
`release/designated-requirement.txt`, `release/exowatt-developer-id.cer`,
`release/provisioning.py`, `release/rcodesign.sh`, `Copper.entitlements`,
`.github/workflows/release.yml`, `release/release-local.sh`, `Sources/Search/Fork/Signing.swift`,
`Sources/Search/Fork/Updates.swift`, `Sources/Search/Fork/Credentials/CopperKeychain.swift`.*

## Cutting a release

```sh
gh workflow run release.yml -R copper-browser/Copper -f ref=fork                  # publish
gh workflow run release.yml -R copper-browser/Copper --ref <branch> -f publish=false   # dry run
gh workflow run release.yml -R copper-browser/Copper -f ref=fork -f runner=macos-15   # on a GitHub-hosted Mac
```

The workflow builds on Copper's own Mac, a self-hosted runner labelled `copper-mini`
(`COPPER_RELEASE=1 ./build.sh release app`), stamps
`<VERSION>.<YYYYMMDD>.<run>` into the bundle, signs it with Exowatt Inc's Developer ID (team
62D5L6T44Y) and the provisioning profile, has Apple notarize it and staples the ticket, makes a
disk image of the stapled app and has that notarized and stapled too, checks the signature and
Gatekeeper's verdict on the zipped bytes and the disk image, launches the zipped app headless and
asks `/health` for its version, and then publishes the zip, the disk image, their `.sha256`s,
`copper-version.json`, `copper-install.sh` and the dSYM as a `v<version>` release. The updater, the curl installer and
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
COPPER_RELEASE_REMOTE_DIR='~/sign-builds/copper' release/release-local.sh   # the mini's folder (the default)
COPPER_RELEASE_BUILD_HERE=~/src/sign-builds/copper release/release-local.sh # build on this Mac (needs Xcode)
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
   latest. The credentials are exo-macsign's (*How a release is signed*): `EXO_MACSIGN_*` in the
   environment, or the files in `~/.config/exowatt-apple-signing` (`EXO_MACSIGN_CONFIG_DIR`),
   mode 0600; the `.p12` must hold `release/exowatt-developer-id.cer`, and the requirement and the
   bundle must name its team.
2. **Build on the mini** (`felipe-exowatt@100.112.175.26`, over Tailscale). The commit's tree
   goes to a job folder in `~/sign-builds/copper/` on the mini's internal disk, or wherever
   `COPPER_RELEASE_REMOTE_DIR` says (quoted, `~/` is the mini's home). A folder under `/Volumes`
   is refused: the external disk has hung whole sessions. The mini's disk is shared and nearly
   full, so the build starts only with 6 GB free there, checked once it holds the lock, and is
   stopped (its whole process group) if the disk drops under 3 GB while it runs. It compiles
   three configurations (arm64 release, the debug build `swift test` needs, x86_64 release),
   each about 1 GB of `.build`, plus the sources and the two apps with their dSYMs, about 3.5 GB
   in all; every run prints what it used. One heavy job at a time: the build waits for
   `/tmp/exo-sign-build.lock` (`lockf`, `COPPER_RELEASE_LOCK`), which the other signing builds on
   that Mac take too, and runs at `nice 10`. `HOME` and `TMPDIR` point into the job folder, so
   SwiftPM's and the compilers' caches go with it. Then the workflow's build steps run there with
   their assertions: `COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY= ./build.sh release app`,
   `swift test --filter xosInsert` and the Intel cross-build, with Xcode
   (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). With `SEARCH_SIGN_IDENTITY`
   empty, `build.sh` asks the keychain for a Developer ID; here it is handed a `security` that
   finds nothing, so the build is ad hoc as on the runner and no keychain is touched on either
   Mac. The two unsigned apps and their dSYMs come back to the laptop, and the whole job folder
   on the mini is deleted at once.
   `COPPER_RELEASE_BUILD_HERE=<folder>` builds on this Mac instead, the same way, under the same
   lock. It needs the full Xcode: with the Command Line Tools alone, SwiftUI's `@State` (a macro
   from SDK 27 on) has no plugin (*plugin for module 'SwiftUIMacros' not found*). Building
   against an older SDK would compile, but a release is never linked against another SDK than
   the one before it.
3. **Sign on the laptop** with [rcodesign](https://github.com/indygreg/apple-platform-rs)
   (apple-codesign 0.29.0, the `macos-universal` build, pinned by SHA-256 in
   `release/rcodesign.sh` and fetched once into `~/.cache/copper-release/`). It reads the `.p12`
   and its password where they are (`--p12-file`, `--p12-password-file`): no keychain, and the key
   is never copied, printed or sent anywhere. The rest is `package-app.sh`'s (*How a release is
   signed*): the provisioning profile (fetched from App Store Connect once a run), the
   entitlements it allows, the signature inside-out, and `xcrun notarytool submit --wait` with the
   App Store Connect key for the app and again for the disk image, each ticket stapled.
   build.sh's ad-hoc signature is removed first, because rcodesign carries an existing
   signature's flags and entitlements over. `--exclude 'Contents/Resources/**'` keeps rcodesign
   from signing the SwiftPM resource bundle in `Resources` as a bundle of its own; codesign's
   rules treat `Resources` as data, and the bundle's files are sealed one by one, as before.
4. **Check, package, launch.** The workflow's *Check the signature* on the zipped bytes (plus: the
   hardened runtime and no other flag, signed by a Developer ID of the team, the embedded profile
   the one fetched, the entitlements exactly Copper.entitlements and the profile's) and on the
   disk images (signed, stapled, `spctl -t open` accepts them, and the app inside is the zipped
   app: same cdhash, same files, and an `/Applications` link); the versioned and stable zips and
   disk images and their `.sha256`s; the dSYMs; `copper-version.json`, written by the workflow's own code and
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
   folders and defaults, and the WebKit and cache folders the check created are deleted. The
   launch log must show no `amfid` or AMFI refusal of the app (an entitlement the profile doesn't
   allow kills a Developer ID app at launch).
5. **Publish** (not in a dry run): the tag is checked once more (a workflow run may have taken the
   number during the build), then `gh release create v<version> --target <commit> --latest` with
   every asset and the workflow's release text (with `release/release-note.md` above it, when
   there is one), and the published bytes are checked — the versioned zips and disk images, and
   the stable zips, disk images and manifest behind `releases/latest/download`.

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

- **The certificate.** A **Developer ID Application** certificate of Exowatt Inc's Apple
  Developer team: `Developer ID Application: Exowatt Inc (62D5L6T44Y)`, issued by Apple's
  *Developer ID Certification Authority* (G2 Sub-CA), valid 2026-11-26 → 2027-12-26. The public
  half is `release/exowatt-developer-id.cer`; its SHA-1 is
  `a137d2a6bab20e94191267be1395a5ac9d9d4982`. Releases up to 1.0.20261124.124 were signed by
  Collin Rijock's team (95X7XYUVNX, `release/copper-developer-id.cer`, SHA-1
  `d6852ec5c7b2cad290909e6414fb66a9b7678e72`); see *The move to Exowatt's team*.
- **The credentials** are exo-macsign's, Exowatt's one set for signing Mac apps
  (`Exowatt-Labs/exo-macsign`): the Developer ID Application key and certificate as a `.p12`
  (the key and the certificate only: rcodesign takes the first certificate in a p12 as the
  signer, so Apple's intermediate is `release/DeveloperIDG2CA.cer`), its password, and an App
  Store Connect API key that notarizes and fetches the provisioning profile. `release/package-app.sh`
  reads each from the environment first, then from its folder (`EXO_MACSIGN_CONFIG_DIR`, default
  `~/.config/exowatt-apple-signing`, files mode 0600 or 0400, the folder 0700):

  | Environment | File in the folder | What |
  |---|---|---|
  | `EXO_MACSIGN_P12_BASE64` | `developer-id-application.p12` | the Developer ID Application key and certificate |
  | `EXO_MACSIGN_P12_PASSWORD` | `p12-password` | its password |
  | `EXO_MACSIGN_ASC_KEY_P8_BASE64` | `AuthKey_<key id>.p8` | the App Store Connect API key |
  | `EXO_MACSIGN_ASC_KEY_ID` | `asc-key-id` | its id |
  | `EXO_MACSIGN_ASC_ISSUER` | `asc-issuer` | its issuer |
  | `EXO_MACSIGN_TEAM_ID` | `team-id` | 62D5L6T44Y, checked against the certificate |
  | `COPPER_PROFILE` | `Copper_Developer_ID.provisionprofile` | the profile, when App Store Connect can't be reached |

  The repository secrets of the same `EXO_MACSIGN_*` names hold them for the workflow; the
  secrets alone can't be read back out of GitHub. Values from the environment are written into
  0600 files of the run's own and deleted when it exits. The `COPPER_DEVELOPER_ID_P12_*`,
  `COPPER_NOTARY_*` and `COPPER_SIGNING_P12_*` secrets are the team before's, kept but no longer
  read. Neither is ever in the repository, and no step makes, reads or changes a keychain:
  rcodesign reads the `.p12` itself and notarytool the `.p8`.
- **The provisioning profile.** A Developer ID provisioning profile, *Copper Developer ID*, for
  the explicit App ID `62D5L6T44Y.com.collinrijock.copper` (App Store Connect bundle id
  resource 564BZ279AL), with that certificate. `release/provisioning.py fetch` signs an App Store
  Connect token with the `.p8` (openssl), finds the bundle id and takes its newest active
  `MAC_APP_DIRECT` profile that is for this team, this bundle id and this certificate; when App
  Store Connect can't be reached, the profile in the folder does, after the same checks. It is
  embedded as `Contents/embedded.provisionprofile` before signing. A profile is what lets a
  Developer ID app hold restricted entitlements: without one, AMFI kills it at launch.
- **The entitlements** are `Copper.entitlements` — what the hardened runtime would otherwise
  refuse: the camera, the microphone, calendars, location (pages ask for these) and Apple Events
  (links handed to the running Copper, `Fork/LinkRelay.swift`) — plus the restricted ones,
  derived from the profile and never written by hand (`release/provisioning.py entitlements`):
  `com.apple.application-identifier` and `com.apple.developer.team-identifier` (what the profile
  says), `keychain-access-groups` narrowed to `62D5L6T44Y.com.collinrijock.copper` (the profile
  allows `62D5L6T44Y.*`; Copper claims only its own group), and
  `com.apple.developer.web-browser.public-key-credential` only when the profile grants it (not
  yet: *Passkeys* below). `Copper.entitlements` itself may claim none of these; the script stops
  if it does. WebKit's JIT runs in WebKit's own processes, so the app needs no JIT entitlement.
- **The requirement.** An explicit designated requirement, the one line in
  `release/designated-requirement.txt`:

  ```
  designated => identifier "com.collinrijock.copper" and anchor apple generic
    and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]
    and (certificate leaf[subject.OU] = "62D5L6T44Y" or certificate leaf[subject.OU] = "95X7XYUVNX")
  ```

  That is the requirement Apple's tools give a Developer ID app — Copper's identifier and *any*
  Developer ID Application certificate Apple issued to the team — with both teams: Exowatt's,
  and the one before it (*The move to Exowatt's team*). Renewing the certificate changes nothing
  for macOS or the updater (`Signing.releaseRequirement`). It is compiled with
  `csreq -r release/designated-requirement.txt -b …` (the form rcodesign takes) and read back to
  be sure.
- **Signing**, inside-out, by `rcodesign sign` (rcodesign signs nested code first and the app
  last): the hardened runtime (`--code-signature-flags runtime`), Apple's secure timestamp, the
  entitlements and the requirement. `package-app.sh` refuses to sign a bundle whose id is not
  `com.collinrijock.copper`, whose binary does not pin the team (`Signing.developerIDRequirement`
  — a build without `COPPER_RELEASE=1`), with a `.p12` that doesn't hold
  `release/exowatt-developer-id.cer`, or without the App Store Connect key. Then
  `codesign --verify --deep --strict -R=<requirement>`.
- **Notarized and stapled.** The zip goes to Apple's notary service
  (`xcrun notarytool submit --wait --key AuthKey_<id>.p8 --key-id … --issuer …`, a few minutes);
  on *Accepted* the ticket is stapled to the app and the zip made again around it, so Gatekeeper
  opens a download offline too. The disk image (`hdiutil`, UDZO: the stapled app and an
  `/Applications` link, volume *Copper*) is made from that stapled app, signed with the same
  Developer ID, notarized on its own and stapled. On anything but *Accepted* the run prints
  Apple's log (`notarytool log`) and stops. No installer, cask or page clears the quarantine flag.
- **The checks** (*Check the signature*): `codesign -dr -` must print exactly that requirement
  (Apple's `/* exists */` comments aside); `codesign --verify --deep --strict` and the same with
  `-R="<requirement>"` must pass; the hardened runtime and a secure timestamp must be there, the
  authority a Developer ID of team 62D5L6T44Y, and the entitlements exactly what the embedded
  profile and `Copper.entitlements` make; `xcrun stapler validate` must pass and
  `spctl -a -vvv -t exec` must say `accepted` and `source=Notarized Developer ID`. Each disk
  image: `codesign --verify --strict`, `xcrun stapler validate`, and
  `spctl -a -vv -t open --context context:primary-signature` must say `accepted`,
  `source=Notarized Developer ID`.

Check any copy by hand:

```sh
spctl -a -vv -t exec /Applications/Copper.app      # accepted, source=Notarized Developer ID,
                                                   # origin=Developer ID Application: Exowatt Inc (62D5L6T44Y)
xcrun stapler validate /Applications/Copper.app
codesign --verify --deep --strict -R="$(cat release/designated-requirement.txt)" /Applications/Copper.app
codesign -d --entitlements - --xml /Applications/Copper.app
spctl -a -vv -t open --context context:primary-signature copper-<version>-macos-arm64.dmg
xcrun stapler validate copper-<version>-macos-arm64.dmg
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
isn't signed by a Developer ID of Copper's teams (Exowatt's, or the one before it) as
`com.collinrijock.copper` is refused with *"Copper X isn't
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

### The move to Exowatt's team

From 1.0.20261126.125 on, releases are signed by **Exowatt Inc's** Apple Developer team,
62D5L6T44Y, instead of Collin Rijock's, 95X7XYUVNX — same identifier, same feed, same tap. A
team is part of the requirement, so this is a rotation like the move to Developer ID, with one
difference: 1.0.20261126.124 and every Developer ID release before it pin 95X7XYUVNX alone, and
there was no release in between to bridge them. So:

- **An installed 1.0.20261126.124 (or older) refuses the first Exowatt release**: Settings ›
  Updates says *"isn't signed with Copper's release certificate"*. Its person reinstalls once,
  over the old copy (settings, worlds, cookies and passwords stay, they aren't in the bundle):

  ```sh
  brew upgrade --cask copper            # installed with Homebrew
  curl -fsSL https://github.com/copper-browser/Copper/releases/latest/download/copper-install.sh | sh
  ```

  or the disk image or zip from the release page. Every release from .125 on carries a requirement
  that names **both** teams (*The requirement* above), so it is the bridge from here on: a .125
  accepts updates signed by either team, and nothing else needs reinstalling.
- **The grants go one last time.** macOS stored them against the old team's requirement: turn
  Copper on again in System Settings › Privacy & Security › Full Disk Access and Files & Folders.
  Keychain items made by 95X7XYUVNX's Copper ask once more (*Always Allow*), then move into
  Copper's own keychain group (*Keychain items* below) and stop asking.
- **Later**: once no 95X7XYUVNX-signed Copper is left that a release needs to accept, the
  `previousTeam` clause can go from `release/designated-requirement.txt` and
  `Signing.developerIDRequirement` in one commit. Dropping it changes the requirement, and with
  it every grant: not worth doing on its own.

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

## Keychain items

Copper keeps its own secrets in the keychain: saved passwords and identities (`Vault`), passkeys
(`PasskeyStore`), one-time-code seeds (`KeychainCodes`), shared- and live-folder keys
(`FolderKit`, `FolderSyncCrypto`). Every one goes through `Fork/Credentials/CopperKeychain.swift`.

- **Entitled (a release from 1.0.20261126.125 on):** the app holds
  `keychain-access-groups = [62D5L6T44Y.com.collinrijock.copper]` (from the profile), so its items
  live in the **data-protection keychain** (`kSecUseDataProtectionKeychain`), in that access
  group, readable after first unlock. There an item belongs to the group, not to a requirement
  or an *Always Allow* list: no prompt, ever, and nothing else on the Mac reads it. The group is
  read from the running app's own entitlements (`SecTaskCopyValueForEntitlement`), never assumed.
- **Not entitled** (development builds, ad-hoc builds, tests, releases up to .124): exactly the
  login keychain as before.
- **The move, once.** An entitled Copper still finds what an older one left in the login
  keychain. The first time it reads a secret that is there, it copies the item into the group and
  deletes the old one (the one prompt it may cost); lists show both keychains until then. A
  minute after launch, a background pass counts Copper's items left in the login keychain by name
  only (no secret is read, so nothing asks); when there are none, `keychain.moved` is set and the
  login keychain is never consulted again. Only Copper's own items are moved or deleted: its
  services, and for internet passwords its label too, so another app's password for the same
  site is never touched. `Import` still reads other browsers' items (Chrome Safe Storage) from the
  login keychain, as it must.

## Passkeys

Copper can be the passkey manager for the web pages it shows (`Fork/Passkeys`), which needs the
restricted entitlement `com.apple.developer.web-browser.public-key-credential`. Apple grants it on
request; Exowatt's request is **3G58F7QCC5** (pending). Until it is granted, the profile doesn't
allow it, so releases don't claim it (a Developer ID app that claims an entitlement its profile
doesn't allow is killed at launch), `Preferences.entitledToPasskeys` is false and Copper offers
passkeys through its own form relay.

Once Apple grants it:

1. developer.apple.com › Certificates, Identifiers & Profiles › Identifiers ›
   `com.collinrijock.copper` (62D5L6T44Y): the capability is listed for the App ID now; turn it on
   if it isn't, and save.
2. Profiles › *Copper Developer ID* (Developer ID, X629A3H7T8) › Edit › Save (generate it again):
   a profile only carries the entitlements the App ID had when it was made. Check it:
   `python3 release/provisioning.py fetch --out /tmp/p.provisionprofile && python3 release/provisioning.py show /tmp/p.provisionprofile`
   must list `com.apple.developer.web-browser.public-key-credential: true`. Put it in
   `~/.config/exowatt-apple-signing/Copper_Developer_ID.provisionprofile` too (the fallback).
3. Nothing in the repository changes: the next release fetches the new profile and
   `release/provisioning.py` claims the entitlement because the profile grants it. Its summary
   (and `codesign -d --entitlements - --xml`) shows it; the launch check on the mini proves AMFI
   accepts it.
4. In the shipped app, `Preferences.entitledToPasskeys` turns true by itself (it reads the
   running app's entitlements), and Copper registers as a browser passkey manager. Check a
   sign-in with a passkey on a test site after updating.

## Renewing the certificate

The Developer ID expires on 2027-12-26, and the provisioning profile with it. Renew it before
then (Apple allows a few Developer ID certificates per team at once, so the old one keeps signing
until the new one is in place). Because the requirement names the team, not the certificate, a
renewal needs no bridge and costs nobody a re-grant; a signature made before the expiry stays
valid after it, thanks to the secure timestamp.

1. exo-macsign makes the key and CSR, with openssl and no keychain (`Exowatt-Labs/exo-macsign`,
   README › Credentials), and Exowatt's Account Holder uploads the CSR at developer.apple.com ›
   Certificates › + › **Developer ID Application** › G2 Sub-CA. Then the `.p12`: the key and
   the certificate, nothing else (`openssl pkcs12 -export …`, as exo-macsign's README says).
2. The profile: Profiles › *Copper Developer ID* › Edit › pick the new certificate › Save. A
   profile names its certificates, and `release/provisioning.py` takes only one that names the
   signing one.
3. In one commit, the new certificate as `release/exowatt-developer-id.cer` (its SHA-1 above in
   this page too). Then the secrets, from the files, without printing them:

   ```sh
   cd ~/.config/exowatt-apple-signing
   base64 -i developer-id-application.p12 | tr -d '\n' | gh secret set EXO_MACSIGN_P12_BASE64 -R copper-browser/Copper
   gh secret set EXO_MACSIGN_P12_PASSWORD -R copper-browser/Copper < p12-password
   ```

   `package-app.sh` refuses a `.p12` that doesn't hold `release/exowatt-developer-id.cer`, in the
   workflow and locally.
4. A dry run (`-f publish=false`, or `release/release-local.sh --dry-run`) must sign, notarize and
   pass every check before the next real release.

The App Store Connect key doesn't expire; if it leaks, revoke it (App Store Connect › Users and
Access › Integrations › Team Keys) and replace it with one of the same role, then
`EXO_MACSIGN_ASC_KEY_P8_BASE64` (the `.p8`, base64), `EXO_MACSIGN_ASC_KEY_ID`,
`EXO_MACSIGN_ASC_ISSUER` and the files in `~/.config/exowatt-apple-signing`:

```sh
base64 -i AuthKey_<id>.p8 | tr -d '\n' | gh secret set EXO_MACSIGN_ASC_KEY_P8_BASE64 -R copper-browser/Copper
gh secret set EXO_MACSIGN_ASC_KEY_ID -R copper-browser/Copper < asc-key-id
gh secret set EXO_MACSIGN_ASC_ISSUER -R copper-browser/Copper < asc-issuer
```

**Another team** is a new requirement: a rotation like *The move to Exowatt's team* — a release
whose requirement accepts both teams first, then the switch.

### Keeping the key

The `.p12`, its password and the App Store Connect key are exo-macsign's, kept where its README
says, beside the repository secrets; the secrets alone can't be read back out of GitHub. If the
Developer ID key is lost, renew (above): the requirement names the team, so nothing else
changes. If it leaks, renew at once and ask Apple Developer Support to revoke the old
certificate; they set the revocation date, so copies signed before the leak keep opening.
