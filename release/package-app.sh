#!/bin/bash
# Stamp the release version into a built Copper.app, sign it with Exowatt's
# Developer ID, notarize it, staple the ticket, and zip it.
#
#   release/package-app.sh <path/to/Copper.app> <version> <out-dir> [arm64|x86_64]
#
# Writes to <out-dir>, for <arch> (default arm64, the CPU the binary must be):
#   copper-<version>-macos-<arch>.zip          ditto --keepParent archive (stapled app)
#   copper-<version>-macos-<arch>.zip.sha256   "<hex>  <zip name>" (shasum format)
#   copper-<version>-macos-<arch>.dmg          the stapled app beside /Applications,
#                                              signed, notarized and stapled itself
#   copper-<version>-macos-<arch>.dmg.sha256
# and prints on stdout, one key=value a line:
#   has_cli=true|false   whether the bundle ships the `copper` CLI shim at
#                        Contents/Resources/bin/copper (the cask renders its
#                        `binary` stanza only when it does)
#   notary_id=<uuid>     Apple's notary submission of the app
#   dmg_notary_id=<uuid> and of the disk image
#   profile=<uuid>       the provisioning profile embedded
#
# The credentials are exo-macsign's (Exowatt-Labs/exo-macsign), from the
# environment first, then from its folder (EXO_MACSIGN_CONFIG_DIR, default
# ~/.config/exowatt-apple-signing, 0700, files 0600):
#   EXO_MACSIGN_P12_BASE64        developer-id-application.p12
#   EXO_MACSIGN_P12_PASSWORD      p12-password
#   EXO_MACSIGN_ASC_KEY_P8_BASE64 AuthKey_<key id>.p8
#   EXO_MACSIGN_ASC_KEY_ID        asc-key-id
#   EXO_MACSIGN_ASC_ISSUER        asc-issuer
# Secrets from the environment go into 0600 files in a private folder that is
# deleted on exit; nothing secret is printed. No keychain is read or written:
# rcodesign (pinned, release/rcodesign.sh; COPPER_RCODESIGN names another copy
# of the same version) signs with the .p12 file, notarytool authenticates with
# the .p8.
#
# The provisioning profile (docs/releasing.md › The provisioning profile):
# COPPER_PROFILE names one; otherwise the newest active Developer ID profile
# for the App ID is fetched from App Store Connect (release/provisioning.py fetch),
# and when Apple can't be asked, Copper_Developer_ID.provisionprofile in the
# credentials folder is used. It goes into Contents/embedded.provisionprofile,
# and the entitlements are Copper.entitlements plus the restricted ones it
# allows (release/provisioning.py entitlements): the app identifier, the team, the
# keychain access group and, once Apple grants it, the passkey entitlement.
#
# Why stamp: Copper's build.sh writes CFBundleShortVersionString from the
# VERSION file (1.0) and CFBundleVersion from the build clock. Homebrew needs a
# monotonic, unique version per release, so a release is
# <VERSION>.<YYYYMMDD>.<n> and this script stamps that same string into the
# bundle so the About box / MCP serverInfo.version match the cask. Editing
# Info.plist invalidates the signature, hence the signing after it.
#
# Why this signature (docs/releasing.md): macOS files a person's grants — Full
# Disk Access, Files & Folders, Automation — and a keychain item's "Always
# Allow" under the app's designated requirement. Signed with the explicit
# requirement in release/designated-requirement.txt (Copper's identifier and
# any Developer ID of Copper's teams, Exowatt's and the one before it), every
# release satisfies the same requirement and the grants carry over, through a
# renewed certificate too. Gatekeeper opens a notarized app with the hardened
# runtime and a secure timestamp, and the entitlements in Copper.entitlements
# are what the runtime would otherwise refuse (camera, microphone, calendars,
# location, Apple Events). The certificate in the .p12 must be the one in
# release/exowatt-developer-id.cer, so a secret holding any other fails here.
#
# COPPER_NOTARIZE=0 signs (Developer ID, profile, entitlements, requirement,
# the disk image too) but sends nothing to Apple: no notarization, no
# stapling; the dry run of a release (release/release-local.sh --dry-run).
# notary_id and dmg_notary_id are then "none".
#
# COPPER_PACKAGE_STATE=<folder> makes a notarizing run resumable: each phase
# (signed, the app's ticket stapled, the disk image signed, its ticket
# stapled) is marked there with the SHA-256 of what it left in <out-dir>, and
# each notary submission's id is kept by the SHA-256 of the bytes sent
# (release/notary.sh). Run again with the same app, version, out-dir and state
# and it carries on where it stopped: it never signs again what it signed, and
# never sends Apple bytes it already sent; it waits on that submission. Past
# the notary deadline (COPPER_NOTARY_DEADLINE / COPPER_NOTARY_HOURS) with Apple
# still working, it exits 75: run again.
#
# COPPER_ADHOC=1 signs ad hoc and doesn't notarize, for trying this script out
# without credentials; a release refuses such a bundle.
set -euo pipefail

app="${1:?usage: package-app.sh <Copper.app> <version> <out-dir> [arm64|x86_64]}"
version="${2:?version}"
out="${3:?out-dir}"
arch="${4:-arm64}"
here="$(cd "$(dirname "$0")" && pwd)"
fail() { printf 'package-app: %s\n' "$*" >&2; exit 1; }
say() { printf '%-8s%s\n' "$1" "$2" >&2; }

[ -d "$app/Contents" ] || fail "not an app bundle: $app"
case "$version" in
  [0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
  *) fail "version must look like 1.0.20260924.3, got: $version" ;;
esac
case "$arch" in
  arm64 | x86_64) ;;
  *) fail "arch must be arm64 or x86_64, got: $arch" ;;
esac
# The zip's name promises a CPU; the binary inside has to keep it.
built="$(lipo -archs "$app/Contents/MacOS/Copper")"
[ "$built" = "$arch" ] || fail "$app is built for $built, not $arch"

plist="$app/Contents/Info.plist"
requirement="$(tr -d '\n' < "$here/designated-requirement.txt")"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
if [ -x "$app/Contents/Resources/bin/copper" ]; then has_cli=true; else has_cli=false; fi
mkdir -p "$out"
zip="$out/copper-${version}-macos-${arch}.zip"
dmg="$out/copper-${version}-macos-${arch}.dmg"
notarizing=true
[ "${COPPER_NOTARIZE:-1}" != 0 ] || notarizing=false

# Where a run that stopped left off (COPPER_PACKAGE_STATE): a phase counts only
# when the file it left is still there, byte for byte.
state="${COPPER_PACKAGE_STATE:-}"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
at() { [ -n "$state" ] && [ -f "$state/$1" ] && [ -f "$2" ] && [ "$(cat "$state/$1")" = "$(sha "$2")" ]; }
mark() { [ -z "$state" ] || sha "$2" > "$state/$1"; }
[ -z "$state" ] || mkdir -p "$state"
resume=""
if $notarizing && [ -n "$state" ] && [ "${COPPER_ADHOC:-}" != 1 ]; then
  if at dmg-stapled "$dmg" && at app-stapled "$zip"; then
    resume="done"
  elif at dmg-signed "$dmg" && at app-stapled "$zip"; then
    resume="dmg-notary"
  elif at app-stapled "$zip"; then
    resume="dmg"
  elif at app-signed "$zip"; then
    resume="app-notary"
  fi
fi
if [ -z "$resume" ]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$plist"
  rm -f "$zip" "$zip.sha256" "$dmg" "$dmg.sha256"
  [ -z "$state" ] || rm -f "$state"/app-signed "$state"/app-stapled "$state"/dmg-signed "$state"/dmg-stapled
else
  say resume "$arch: carrying on from $resume ($state)"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" = "$version" ] \
    || fail "$app is not stamped $version, but $state says it was signed as that; delete $state to start again"
fi
# Nothing but the bundle: no extended attributes (this Mac's com.apple.provenance
# would become ._ AppleDouble files that a plain unzip leaves in the bundle,
# unsealed), no resource forks, no quarantine, no ACLs.
pack() { ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app" "$zip"; }
finish() {
  (cd "$out" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
  [ ! -f "$dmg" ] || (cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
  say stamped "$(plutil -extract CFBundleShortVersionString raw -o - "$plist") (build $(plutil -extract CFBundleVersion raw -o - "$plist"))"
  say packed "$zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
  echo "has_cli=$has_cli"
}

if [ "${COPPER_ADHOC:-}" = 1 ]; then
  # Why --deep: the bundle has no nested code today, but a future build might.
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"
  say signed "ad hoc (COPPER_ADHOC=1): not a release"
  pack
  finish
  exit 0
fi

# ---------------------------------------------------------------------------
# The credentials

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
conf="${EXO_MACSIGN_CONFIG_DIR:-$HOME/.config/exowatt-apple-signing}"
private_file() {
  local file="$1" mode
  [ -f "$file" ] || fail "missing $file (docs/releasing.md › Credentials)"
  mode="$(stat -f %Lp "$file" 2> /dev/null || stat -c %a "$file")"
  case "$mode" in 600 | 400) ;; *) fail "$file is mode $mode; it must be 0600" ;; esac
  printf '%s' "$file"
}
value() { # value ENV_VAR FILE_NAME: the variable, else the file, trimmed
  local var="$1" name="$2"
  if [ -n "${!var:-}" ]; then printf '%s' "${!var}" | tr -d ' \t\r\n'; return; fi
  [ -f "$conf/$name" ] && tr -d ' \t\r\n' < "$conf/$name"
  return 0
}
secret_from_env() { # secret_from_env ENV_VAR OUT [base64]
  local var="$1" file="$2"
  (
    umask 077
    if [ "${3:-}" = base64 ]; then
      case "${!var}" in
        -----BEGIN*) printf '%s\n' "${!var}" > "$file" ;;
        *) printf '%s' "${!var}" | tr -d ' \t\r\n' | base64 --decode > "$file" 2> /dev/null || exit 1 ;;
      esac
    else
      printf '%s' "${!var}" > "$file"
    fi
  ) || fail "$var is not valid base64"
}

if [ -n "${EXO_MACSIGN_P12_BASE64:-}" ]; then
  p12="$work/signing.p12"
  secret_from_env EXO_MACSIGN_P12_BASE64 "$p12" base64
else
  p12="$(private_file "$conf/developer-id-application.p12")"
fi
if [ -n "${EXO_MACSIGN_P12_PASSWORD+set}" ]; then
  p12_password="$work/signing.p12-password"
  secret_from_env EXO_MACSIGN_P12_PASSWORD "$p12_password"
else
  p12_password="$(private_file "$conf/p12-password")"
fi
notary_key_id="$(value EXO_MACSIGN_ASC_KEY_ID asc-key-id)"
notary_issuer="$(value EXO_MACSIGN_ASC_ISSUER asc-issuer)"
[ -n "$notary_key_id" ] || fail "no App Store Connect key id: EXO_MACSIGN_ASC_KEY_ID or $conf/asc-key-id"
[ -n "$notary_issuer" ] || fail "no App Store Connect issuer: EXO_MACSIGN_ASC_ISSUER or $conf/asc-issuer"
if [ -n "${EXO_MACSIGN_ASC_KEY_P8_BASE64:-}" ]; then
  notary_key="$work/AuthKey.p8"
  secret_from_env EXO_MACSIGN_ASC_KEY_P8_BASE64 "$notary_key" base64
else
  notary_key="$(private_file "$conf/AuthKey_$notary_key_id.p8")"
fi
grep -q 'BEGIN PRIVATE KEY' "$notary_key" || fail "the App Store Connect key is not a PEM private key (AuthKey_<key id>.p8)"

# The certificate in the .p12 is the one in release/, and its team is one the
# requirement accepts (hashes and teams are public).
want="$(shasum -a 1 < "$here/exowatt-developer-id.cer" | cut -d' ' -f1)"
have="$(openssl pkcs12 -in "$p12" -passin "file:$p12_password" -nokeys -clcerts 2> /dev/null \
  | openssl x509 -outform der 2> /dev/null | shasum -a 1 | cut -d' ' -f1)"
[ "$have" = "$want" ] || fail "the .p12 does not hold release/exowatt-developer-id.cer ($want). Renewed? See docs/releasing.md › Renewing the certificate."
team="$(openssl x509 -inform der -in "$here/exowatt-developer-id.cer" -noout -subject | sed -n 's/.*OU *= *\([0-9A-Z]*\).*/\1/p')"
[ -n "$team" ] || fail "no team (OU) in release/exowatt-developer-id.cer"
configured="$(value EXO_MACSIGN_TEAM_ID team-id)"
[ -z "$configured" ] || [ "$configured" = "$team" ] || fail "team-id is $configured, the certificate is team $team"

# A release is Copper itself; a development build (com.collinrijock.copper.dev,
# build.sh without COPPER_RELEASE=1) would sign fine and then never satisfy
# the requirement — or replace anyone's Copper.
case "$requirement" in
  *"identifier \"$bundle_id\" "*) ;;
  *) fail "bundle id $bundle_id is not the release's ($requirement): build with COPPER_RELEASE=1" ;;
esac
case "$requirement" in
  *"certificate leaf[subject.OU] = \"$team\""*) ;;
  *) fail "release/designated-requirement.txt does not accept team $team" ;;
esac
# The updater inside checks every later release against the same teams
# (Fork/Signing.swift). A bundle that doesn't accept this one would refuse the
# next update, so it is not signed at all.
LC_ALL=C grep -a -q -F "certificate leaf[subject.OU] = \"$team\"" "$app/Contents/MacOS/Copper" \
  || fail "the app's updater does not accept team $team (Fork/Signing.swift): refusing to sign it for that team"

# The signer: COPPER_RCODESIGN, else an rcodesign of the pinned version on
# PATH (a CI agent's), else the pinned one release/rcodesign.sh fetches.
rcodesign="${COPPER_RCODESIGN:-$("$here/rcodesign.sh")}"
case "$("$rcodesign" --version)" in
  "apple-codesign 0.29.0"*) ;;
  *) fail "$rcodesign is $("$rcodesign" --version), not the pinned 0.29.0 (release/rcodesign.sh)" ;;
esac

if [ -z "$resume" ]; then
  # -------------------------------------------------------------------------
  # The profile and the entitlements

  profile="$work/embedded.provisionprofile"
  if [ -n "${COPPER_PROFILE:-}" ]; then
    cp "$COPPER_PROFILE" "$profile"
    say profile "$COPPER_PROFILE (COPPER_PROFILE)"
  elif python3 "$here/provisioning.py" fetch --key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer" \
    --bundle-id "$bundle_id" --team "$team" --cert-sha1 "$want" --out "$profile"; then
    :
  else
    cp "$(private_file "$conf/Copper_Developer_ID.provisionprofile")" "$profile"
    say profile "App Store Connect could not be asked; using $conf/Copper_Developer_ID.provisionprofile"
  fi
  python3 "$here/provisioning.py" entitlements --base "$here/../Copper.entitlements" --profile "$profile" \
    --bundle-id "$bundle_id" --team "$team" --cert-sha1 "$want" --out "$work/entitlements.plist"
  profile_uuid="$(python3 "$here/provisioning.py" uuid --profile "$profile")"

  # -------------------------------------------------------------------------
  # Sign, inside out

  # rcodesign takes the requirement compiled, not as text; csreq compiles it the
  # way codesign -r would, and gives it back as written.
  printf '%s\n' "$requirement" > "$work/requirement.txt"
  csreq -r "$work/requirement.txt" -b "$work/requirement.bin"
  [ "$(csreq -r "$work/requirement.bin" -t | sed 's: /\* exists \*/::g')" = "$requirement" ] || fail "csreq did not round-trip the requirement"

  # rcodesign carries an existing signature's flags and entitlements over, so
  # build.sh's ad-hoc one goes first: the release signature has only what is
  # given below.
  codesign --remove-signature "$app"
  rm -rf "$app/Contents/_CodeSignature"
  install -m 644 "$profile" "$app/Contents/embedded.provisionprofile"
  # One pass, inside out: nested code first (none today), then the app with the
  # entitlements and the explicit requirement (rcodesign applies both to the
  # main executable only). Contents/Resources is data, as codesign's own rules
  # have it: the SwiftPM resource bundle there is sealed file by file, not signed
  # as a bundle of its own. The profile is sealed with the rest of Contents.
  "$rcodesign" sign \
    --p12-file "$p12" --p12-password-file "$p12_password" \
    --code-requirements-file "$work/requirement.bin" \
    --code-signature-flags runtime \
    --entitlements-xml-file "$work/entitlements.plist" \
    --exclude 'Contents/Resources/**' \
    "$app" > "$work/rcodesign.log" 2>&1 \
    || { tail -20 "$work/rcodesign.log" >&2; fail "rcodesign could not sign the $arch app"; }
else
  profile_uuid="$(python3 "$here/provisioning.py" uuid --profile "$app/Contents/embedded.provisionprofile")"
fi
if ! codesign --verify --deep --strict -R="$requirement" "$app"; then
  fail "the $arch app does not satisfy $requirement"
fi
say signed "$(codesign -d -r- "$app" 2> /dev/null | grep '^designated')"

# ---------------------------------------------------------------------------
# Notarize, staple, zip, disk image

# shellcheck source=release/notary.sh
. "$here/notary.sh"
notary="$work/notary"
[ -z "$state" ] || notary="$state/notary"
id=none
dmg_id=none

if [ -z "$resume" ]; then
  pack
  mark app-signed "$zip"
fi
if $notarizing; then
  if [ -z "$resume" ] || [ "$resume" = "app-notary" ]; then
    # The ticket is stapled to the app, so Gatekeeper accepts it offline too,
    # and the zip and the disk image are made around the stapled app. A
    # submission can sit "In Progress" for hours (a team's first ones get a
    # closer look, and the queue is shared): release/notary.sh waits on it,
    # never sends it twice.
    id="$(notary_run "$zip" "$arch app" "$notary")"
    [ -z "$state" ] || printf '%s\n' "$id" > "$state/app.id"
    xcrun stapler staple "$app" >&2
    xcrun stapler validate "$app" >&2
    rm -f "$zip"
    pack
    mark app-stapled "$zip"
  else
    id="$(cat "$state/app.id" 2> /dev/null || echo unknown)"
  fi
else
  say notary "$arch: not notarized (COPPER_NOTARIZE=0)"
fi

# The disk image: the app (stapled, when notarizing) beside a shortcut to
# /Applications, signed (it has no designated requirement of its own to keep),
# notarized on its own and stapled, so it opens on a Mac that is offline and
# has never seen Copper.
if [ "$resume" != "dmg-notary" ] && [ "$resume" != "done" ]; then
  rm -f "$dmg"
  stage="$work/dmg"
  mkdir -p "$stage"
  ditto --norsrc --noextattr --noqtn --noacl "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname Copper -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" \
    || fail "hdiutil could not make the $arch disk image"
  rm -rf "$stage"
  "$rcodesign" sign --p12-file "$p12" --p12-password-file "$p12_password" "$dmg" > "$work/rcodesign-dmg.log" 2>&1 \
    || { tail -20 "$work/rcodesign-dmg.log" >&2; fail "rcodesign could not sign the $arch disk image"; }
  mark dmg-signed "$dmg"
fi
if $notarizing; then
  if [ "$resume" != "done" ]; then
    dmg_id="$(notary_run "$dmg" "$arch disk image" "$notary")"
    [ -z "$state" ] || printf '%s\n' "$dmg_id" > "$state/dmg.id"
    xcrun stapler staple "$dmg" >&2
    xcrun stapler validate "$dmg" >&2
    mark dmg-stapled "$dmg"
  else
    dmg_id="$(cat "$state/dmg.id" 2> /dev/null || echo unknown)"
  fi
fi
say packed "$dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
finish
echo "notary_id=$id"
echo "dmg_notary_id=$dmg_id"
echo "profile=$profile_uuid"
