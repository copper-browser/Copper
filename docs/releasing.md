# Releasing and signing

*How a Copper release is built and signed, why the signature has to stay the same from one
release to the next, how development builds stay out of the installed Copper's way, and how to
renew the certificate. Files: `build.sh`, `release/package-app.sh`,
`release/designated-requirement.txt`, `release/exowatt-developer-id.cer`,
`release/provisioning.py`, `release/rcodesign.sh`, `release/notary.sh`, `Copper.entitlements`,
`.woodpecker/release.yaml`, `release/release-ci.sh`, `release/release-local.sh`, `release/bump-tap.sh`, `Sources/Search/Fork/Signing.swift`,
`Sources/Search/Fork/Updates.swift`, `Sources/Search/Fork/Credentials/CopperKeychain.swift`.*

## Cutting a release

Releases are cut on **Roadrunner** (Exowatt's Woodpecker CI, https://cicd.apps.exowatt.com), on its
macOS agent: `.woodpecker/release.yaml`, which runs `release/release-ci.sh`
(`release/release-local.sh --here`) and then `release/bump-tap.sh`. Nobody's laptop and no
person's copy of the certificate is involved: the Developer ID `.p12`, the App Store Connect key
and the bot's GitHub token are Woodpecker secrets of this repository (`exo_macsign_*`,
`github_release_token`), handed to the one step that needs them.

| To | Do |
|---|---|
| **Publish** fork as the next version | Run a manual pipeline on `fork` with the variable `RELEASE=1` (UI: *copper-browser/Copper › Run pipeline*, branch `fork`, add variable `RELEASE` = `1`) |
| Publish a version you name | Push the tag: `git tag v1.0.20261127.126 <commit on fork> && git push origin v1.0.20261127.126` — or `RELEASE=1` plus `VERSION=1.0.20261127.126` |
| **Dry run**: build and sign, nothing else | A manual pipeline on `fork` with `DRY_RUN=1`. Nothing goes to Apple, GitHub or the tap |
| Dry run, notarized too | `DRY_RUN=1` and `NOTARIZE=1` (Apple's queue, nothing published) |
| Carry on a release that stopped | Restart the pipeline (`gh rr rerun`, or *Restart* in the UI), or run `RELEASE=1` again on the same commit |
| Start that over instead | `RELEASE=1` and `FRESH=1` (a new version; Apple's earlier submissions are left to finish on their own) |

Watch it with `gh rr status -R copper-browser/Copper`, `gh rr watch` and `gh rr logs`
(`gh run` only sees GitHub Actions; this repository has no release workflow there any more).

The pipeline, in order:

1. **Clone** the whole history (`depth: 0`) at the commit: `fork`'s head for a manual run, the
   tagged commit for a tag. A release is only ever a commit of `fork`: its head, or one `fork`
   has since moved past.
2. **Release** (`release-ci.sh` → `release-local.sh --here`): the preflight, the version, the
   build with the workflow's assertions (`COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY= ./build.sh
   release app`, `swift test --filter xosInsert`, the Intel cross-build) with the agent's Xcode
   (`DEVELOPER_DIR`), the signature, notarization and stapling of both CPUs' zips and disk images
   (`package-app.sh`, *How a release is signed*), *Check the signature*, the dSYMs,
   `copper-version.json`, then `gh release create v<version> --target <commit> --latest` as
   `exowatt-woodpecker-bot` and a check of the published bytes. `EXO_MACSIGN_*` are written once
   into 0600 files in a private folder that is deleted when the step ends, and unset, so the
   build never sees them; `GH_TOKEN` is unset for the build too. The signer is the agent's
   `rcodesign` 0.29.0 (`EXO_MACSIGN_RCODESIGN`, else the one on `PATH`, else the pinned
   download). The agent is a LaunchDaemon with no login session, so the headless launch check
   (step 4 below) is skipped there; every signature, entitlement and Gatekeeper check still runs.
3. **Tap**: `release/bump-tap.sh` renders `Casks/copper.rb` with the tap's own
   `scripts/bump.mjs` from the release's `copper-version.json` (each zip's `.sha256` checked
   against it) and commits it to `copper-browser/homebrew-copper` main through GitHub's contents
   API as the bot, conditional on the file it read. It never moves the tap back and is a no-op
   when the cask already names the release, so a rerun is harmless. Not in a dry run.

**Apple's queue takes hours sometimes.** Each CPU's app and disk image is a submission of its own
(`release/notary.sh`): submitted once (`notarytool submit` without `--wait`), its id kept at once
by the SHA-256 of the bytes sent, then waited on by id (`notarytool info`/`wait`, 30 minutes at
a time). The step waits until 45 minutes before the pipeline's timeout (the repository's
Woodpecker timeout is 600 minutes; `COPPER_NOTARY_DEADLINE` / `COPPER_NOTARY_HOURS` change it).
Past that with Apple still *In Progress*, it stops with exit 75 (*Apple is still notarizing*),
publishing nothing. Everything is kept on the agent in `~roadrunner/copper-release/<version>/`,
outside the workspace Woodpecker deletes: the built apps, each signed zip and disk image with the
phase it reached, the profile it was signed with and every submission id. Restart the pipeline
(or `RELEASE=1` again on that commit) and it takes the same version, builds and signs nothing it
has, never sends Apple the same bytes twice — it waits on the same submission — and publishes
once both CPUs are *Accepted*. The same goes for a pipeline killed by its timeout, a lost agent
or a failed upload: a draft a stopped `gh release create` left is deleted and made again. Once a
commit is released, any later run of it (the tag event of its own release, a rerun) says so and
exits 0; `--again` releases a commit a second time, as a new version. Unfinished state is pruned
after 14 days.

**What still needs the agent.** The pipeline asks for `platform: darwin/arm64, tier: macos`.
Until a company Mac is registered with that label (`Exowatt-Labs/cicd` docs/macos.md › *Bring up a
macOS agent*), a run waits in the queue and nothing is built; cut the release by hand meanwhile
(below). Personal machines, Felipe's Mac mini included, are never registered as agents.

**Block lists first** (once a release, on a Mac): `tools/shield/refresh.py`, then commit what
changed in `Sources/Search/Resources/shield`. It fetches EasyList, EasyPrivacy, uBlock's
filters, the cookie-notice lists and the regional lists and converts them for WebKit
(tools/shield/README.md); the app compiles each new version once, on first launch.

**Two CPUs.** Every release is built twice on the same Apple Silicon Mac: natively for
`arm64`, and cross-built for Intel with `COPPER_ARCH=x86_64 ./build.sh release app`
(`swift build --triple x86_64-apple-macosx14.0`, into `build/x86_64/Copper.app`). Both are
stamped and signed the same way (`release/package-app.sh … <arch>`, which refuses a binary that
isn't that CPU), both are checked, and both are launched when there is a login session — the
Intel one through Rosetta, when the Mac has it (`softwareupdate --install-rosetta
--agree-to-license`; without it the run warns and skips only that launch). Each CPU gets
`copper-<version>-macos-<arch>.zip`, its stable `copper-macos-<arch>.zip` name, the disk images,
the `.sha256`s and a dSYM. `copper-version.json` lists both under `archives`; its top-level
`zip`, `sha256` and `archiveUrl` stay arm64's, which is all a Copper from before the Intel build
reads. The updater (`Fork/Updates.swift`) takes its own CPU's archive — an Intel Copper never
falls back to the arm64 one — and checks the unpacked bundle's architecture before the swap.
The curl installer picks by `uname -m` (arm64 under a Rosetta shell), and the tap's cask
switches with Homebrew's `arch` stanza.

**A dry run** (`DRY_RUN=1`, `--dry-run`) builds and signs both CPUs exactly as a release does
(Developer ID, profile, entitlements, requirement, the disk images too) and runs every check
that doesn't need Apple's ticket, then stops: nothing is sent to Apple's notary service (unless
`NOTARIZE=1` / `--notarize`), no tag, no GitHub release, no upload, no tap. The version is the
one a release would take; dry runs build any commit.

## Cutting a release by hand (the fallback)

```sh
release/release-local.sh --preflight                  # the checks before the build, nothing more
release/release-local.sh --dry-run                    # build, sign, check, launch; nothing to Apple, nothing published
release/release-local.sh --dry-run --notarize         # and notarize, staple and check that too
release/release-local.sh                              # publish fork's HEAD as the next version
release/release-local.sh --version 1.0.20261111.106   # a version of your choosing
release/release-local.sh --reuse-assets <commit>      # publish what a run that stopped after notarizing left
release/release-local.sh --here …                     # everything on this Mac (what the pipeline runs)
COPPER_RELEASE_REMOTE_DIR='~/sign-builds/copper' release/release-local.sh   # the mini's folder (the default)
COPPER_RELEASE_BUILD_HERE=~/src/sign-builds/copper release/release-local.sh # build on this Mac (needs Xcode)
release/bump-tap.sh [<version>]                       # point the tap at a release (default: the latest)
```

When Roadrunner can't (no macOS agent yet, or it is down), the same script cuts the release from
Felipe's laptop: it builds on his Mac mini, signs on the laptop and publishes with `gh` as whoever
is signed in (an owner of `copper-browser`), then bumps the tap. It is the pipeline's own script,
so the release is the same — the same build commands and checks, the same certificate and
requirement, the same assets, `copper-version.json` and release text — and the updater, the curl
installer and the tap can't tell where it was cut. A stopped run carries on exactly as in the
pipeline (its state is in `build/release-local/<version>/`, or `COPPER_RELEASE_OUT`).

In order:

1. **Preflight.** `HEAD` must be a commit of `fork` on GitHub and the tree clean; a dry run says
   when it isn't and goes on, since it builds the commit (`git archive`), never the working tree.
   The version is `<VERSION>.<UTC YYYYMMDD>.<n>`, `n` one more than the highest trailing number
   of any `v…` tag or release in the repository, so it never takes a number already used or
   sorts below one. `--version` picks it instead; it must be new (or a tag pushed on this commit
   with no release yet), and to publish, above the latest. A commit that already has a release is
   not released again (`--again` does). The credentials are exo-macsign's (*How a release is
   signed*): `EXO_MACSIGN_*` in the environment, or the files in `~/.config/exowatt-apple-signing`
   (`EXO_MACSIGN_CONFIG_DIR`), mode 0600; the `.p12` must hold `release/exowatt-developer-id.cer`,
   and the requirement and the bundle must name its team. One run at a time per state folder.
2. **Build on the mini** (`felipe-exowatt@100.112.175.26`, over Tailscale; `--here`: on this
   Mac). The commit's tree goes to a job folder in `~/sign-builds/copper/` on the mini's internal
   disk, or wherever `COPPER_RELEASE_REMOTE_DIR` says (quoted, `~/` is the mini's home). A folder
   under `/Volumes` is refused: the external disk has hung whole sessions. The mini's disk is
   shared and nearly full, so the build starts only with 6 GB free there, checked once it holds
   the lock, and is stopped (its whole process group) if the disk drops under 3 GB while it runs.
   It compiles three configurations (arm64 release, the debug build `swift test` needs, x86_64
   release), each about 1 GB of `.build`, plus the sources and the two apps with their dSYMs,
   about 3.5 GB in all; every run prints what it used. One heavy job at a time: the build waits
   for `/tmp/exo-sign-build.lock` (`lockf`, `COPPER_RELEASE_LOCK`), which the other signing
   builds on that Mac take too, and runs at `nice 10`. `HOME` and `TMPDIR` point into the job
   folder, so SwiftPM's and the compilers' caches go with it. Then the build steps run there with
   their assertions: `COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY= ./build.sh release app`,
   `swift test --filter xosInsert` and the Intel cross-build, with the Xcode `DEVELOPER_DIR`
   names, else `/Applications/Xcode.app`. With `SEARCH_SIGN_IDENTITY` empty, `build.sh` asks the
   keychain for a Developer ID; here it is handed a `security` that finds nothing, so the build is
   ad hoc and no keychain is touched on either Mac. The two unsigned apps and their dSYMs come back
   to the laptop, and the whole job folder on the mini is deleted at once.
   `COPPER_RELEASE_BUILD_HERE=<folder>` builds on this Mac instead, the same way, under the same
   lock. It needs the full Xcode: with the Command Line Tools alone, SwiftUI's `@State` (a macro
   from SDK 27 on) has no plugin (*plugin for module 'SwiftUIMacros' not found*). Building
   against an older SDK would compile, but a release is never linked against another SDK than
   the one before it.
3. **Sign on the laptop** with [rcodesign](https://github.com/indygreg/apple-platform-rs)
   (apple-codesign 0.29.0: an `rcodesign` of that version on `PATH`, else the `macos-universal`
   build pinned by SHA-256 in `release/rcodesign.sh` and fetched once into
   `~/.cache/copper-release/`). It reads the `.p12` and its password where they are
   (`--p12-file`, `--p12-password-file`): no keychain, and the key is never copied, printed or
   sent anywhere. The rest is `package-app.sh`'s (*How a release is signed*): the provisioning
   profile (fetched from App Store Connect once a run), the entitlements it allows, the signature
   inside-out, and Apple's notary service for the app and again for the disk image, each ticket
   stapled (not in a dry run). build.sh's ad-hoc signature is removed first, because rcodesign
   carries an existing signature's flags and entitlements over. `--exclude
   'Contents/Resources/**'` keeps rcodesign from signing the SwiftPM resource bundle in
   `Resources` as a bundle of its own; codesign's rules treat `Resources` as data, and the
   bundle's files are sealed one by one, as before.
4. **Check, package, launch.** *Check the signature* on the zipped bytes (the requirement, the
   hardened runtime and no other flag, signed by a Developer ID of the team, the embedded profile
   the one fetched, the entitlements exactly Copper.entitlements and the profile's, and — when
   notarized — the stapled ticket and Gatekeeper's verdict) and on the disk images (signed,
   stapled, `spctl -t open` accepts them, and the app inside is the zipped app: same cdhash, same
   files, and an `/Applications` link); the versioned and stable zips and disk images and their
   `.sha256`s; the dSYMs; `copper-version.json`, held to the fields of the manifest
   `releases/latest` serves; `copper-install.sh`. The zips are `ditto -c -k --norsrc
   --noextattr --noqtn --noacl --keepParent`: the laptop gives every file a
   `com.apple.provenance` attribute, which plain `ditto` stores as `._` files that a plain
   `unzip` would leave inside the bundle, unsealed. Then both zips are opened headless on the
   mini (`--here`: on this Mac, when this account has a login session), in throwaway worlds on
   free ports, and `/health` must report the version within 90 s (the Intel app under Rosetta,
   120 s). An app has to start in the session of whoever is logged in there: `open` over ssh has
   no window server (LaunchServices answers -10810) and `launchctl asuser` needs root, so a
   one-shot agent in that session's launchd domain (`launchctl bootstrap gui/<uid>`) runs the
   `open`. The two apps are unzipped into the user's temporary folder on the internal disk. Only
   those pids are stopped; the apps, the worlds' folders and defaults, and the WebKit and cache
   folders the check created are deleted. The launch log must show no `amfid` or AMFI refusal of
   the app (an entitlement the profile doesn't allow kills a Developer ID app at launch).
5. **Publish** (not in a dry run): the tag is checked once more (another run may have taken the
   number during the build), then `gh release create v<version> --target <commit> --latest` with
   every asset and the release text (with `release/release-note.md` above it, when there is one),
   and the published bytes are checked — the versioned zips and disk images, and the stable
   zips, disk images and manifest behind `releases/latest/download`. Then `release/bump-tap.sh`
   points the tap at it (a failure there is a warning: the release is out; run it again).

**A run that stops after notarizing** carries on by itself when run again on the same commit
(above). `--reuse-assets <commit they were built from>` is for when the fix is a new commit: it
checks, launches and publishes the assets in `build/release-local/<version>/` instead of building
and notarizing again; the release is that commit, whose tree must be HEAD's but for
`release/release-local.sh` and `docs/`. Their dSYMs went with the unsigned build, so that release
has none (crash reports from it won't symbolicate).

Everything lands in `build/release-local/<version>/` (gitignored; dry runs in `dry-run/<version>/`):
`assets/` is exactly what a release uploads, `release-notes.md` its text, `logs/` the build and
launch output and rcodesign's, `build/` and `state/` what a stopped run carries on from (gone
once it is published). The job folder on the mini is deleted at the end, whatever happened.

**rcodesign, not codesign.** The requirement, the flags (the hardened runtime), the entitlements,
the sealed resources (the same `CodeResources`), the certificate and the signed attributes are
what codesign would make, and `codesign` verifies them the same way. rcodesign hashes code in
4 KB pages where codesign uses 16 KB for arm64 (x86_64 is 4 KB in both), so the arm64 signature
is about 140 KB instead of 36. That is not part of the designated requirement: macOS keeps a
person's grants and an installed Copper's updater accepts the bundle exactly as it would a
codesign one (`codesign --verify --deep --strict -R=…`), and the kernel checks 4 KB pages on
Apple silicon as it does on Intel. (Notarizing an rcodesign signature is rcodesign's documented
use.) The first dry run was rehearsed against the real thing: Copper 1.0.20261110.104 as
released, headless in a test world pointed at a stub feed, staged the rcodesign-signed
1.0.20261110.105 and passed the pre-swap check (`updates dry-run on`, then `updates upgrade`).

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

  Roadrunner's repository secrets `exo_macsign_*` hold them for the pipeline (pushed by
  exo-macsign's `tools/rr-secrets.sh`); GitHub's repository secrets of the `EXO_MACSIGN_*`
  names are left from the GitHub Actions workflow, which is gone. Neither can be read back
  out. Values from the environment are written into 0600 files in the run's own private folder,
  deleted when it exits, and unset before the build. The `COPPER_DEVELOPER_ID_P12_*`,
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
- **Notarized and stapled** (`release/notary.sh`). The zip goes to Apple's notary service
  (`xcrun notarytool submit --key AuthKey_<id>.p8 --key-id … --issuer …`, without `--wait`) and
  the submission id is kept at once, by the SHA-256 of the bytes sent, so these bytes are never
  sent again; the id is then asked after (`notarytool info`, `notarytool wait` 30 minutes at a
  time). That usually takes minutes, but the queue is shared with every app the team signs and a
  new team's first submissions get a closer look: on 2026-11-26 each took over an hour, and on
  2026-11-27 submissions sat *In Progress* for more than 11 hours. It waits until
  `COPPER_NOTARY_DEADLINE` (the pipeline: 45 minutes before its timeout; by hand:
  `COPPER_NOTARY_HOURS`, default 4) and then stops with 75, keeping the ids, for the next run
  to wait on (*Cutting a release*); `release-local.sh` packages the two CPUs side by side, so
  they wait together. On *Accepted* the ticket is stapled to the app and the zip made again
  around it, so Gatekeeper opens a download offline too. The disk image (`hdiutil`, UDZO: the
  stapled app and an `/Applications` link, volume *Copper*) is made from that stapled app,
  signed with the same Developer ID, notarized on its own and stapled. On *Invalid* or
  *Rejected* the run prints Apple's log (`notarytool log`) and stops. No installer, cask or page
  clears the quarantine flag. `COPPER_NOTARIZE=0` (a dry run) signs everything and sends nothing.
  `release/test-notary.sh` runs `notary.sh` against a stand-in `notarytool`.
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
(every release runs that exact command). From then on, Copper also checks the
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

   ```sh
   S=~/.config/exowatt-apple-signing; K=$(tr -d '\n' < $S/asc-key-id)
   python3 release/provisioning.py fetch --bundle-id com.collinrijock.copper --team 62D5L6T44Y \
     --key $S/AuthKey_$K.p8 --key-id $K --issuer "$(tr -d '\n' < $S/asc-issuer)" --out /tmp/p.provisionprofile
   python3 release/provisioning.py show --profile /tmp/p.provisionprofile
   ```

   must list `com.apple.developer.web-browser.public-key-credential`. Put it in
   `~/.config/exowatt-apple-signing/Copper_Developer_ID.provisionprofile` too (the fallback), and
   `release/release-local.sh --preflight` then shows it under `claims`.
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
   # Roadrunner's exo_macsign_* (all six, from ~/.config/exowatt-apple-signing): in an exo-macsign checkout
   tools/rr-secrets.sh copper-browser/Copper
   ```

   `package-app.sh` refuses a `.p12` that doesn't hold `release/exowatt-developer-id.cer`, in the
   pipeline and locally.
4. A dry run that notarizes (`DRY_RUN=1` and `NOTARIZE=1`, or `release/release-local.sh
   --dry-run --notarize`) must sign, notarize and pass every check before the next real release.

The App Store Connect key doesn't expire; if it leaks, revoke it (App Store Connect › Users and
Access › Integrations › Team Keys) and replace it with one of the same role, then
`EXO_MACSIGN_ASC_KEY_P8_BASE64` (the `.p8`, base64), `EXO_MACSIGN_ASC_KEY_ID`,
`EXO_MACSIGN_ASC_ISSUER` and the files in `~/.config/exowatt-apple-signing`:

```sh
tools/rr-secrets.sh copper-browser/Copper     # in an exo-macsign checkout: Roadrunner's exo_macsign_*
```

**Another team** is a new requirement: a rotation like *The move to Exowatt's team* — a release
whose requirement accepts both teams first, then the switch.

### Keeping the key

The `.p12`, its password and the App Store Connect key are exo-macsign's, kept where its README
says, beside Roadrunner's repository secrets; the secrets alone can't be read back out. If the
Developer ID key is lost, renew (above): the requirement names the team, so nothing else
changes. If it leaks, renew at once and ask Apple Developer Support to revoke the old
certificate; they set the revocation date, so copies signed before the leak keep opening.
