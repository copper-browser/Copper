#!/bin/bash
# Stamp the release version into a built Copper.app, sign it with Copper's
# Developer ID, notarize it, staple the ticket, and zip it.
#
#   COPPER_SIGN_IDENTITY=<sha1> [COPPER_SIGN_KEYCHAIN=<path>] \
#   COPPER_NOTARY_KEY=<AuthKey.p8> COPPER_NOTARY_KEY_ID=<id> COPPER_NOTARY_ISSUER=<uuid> \
#     release/package-app.sh <path/to/Copper.app> <version> <out-dir> [arm64|x86_64]
#
# Writes to <out-dir>, for <arch> (default arm64, the CPU the binary must be):
#   copper-<version>-macos-<arch>.zip          ditto --keepParent archive (stapled app)
#   copper-<version>-macos-<arch>.zip.sha256   "<hex>  <zip name>" (shasum format)
# and prints `has_cli=true|false` on stdout (whether the bundle ships the
# `copper` CLI shim at Contents/Resources/bin/copper — the cask renders its
# `binary` stanza only when it does).
#
# Why stamp: Copper's build.sh writes CFBundleShortVersionString from the
# VERSION file (1.0) and CFBundleVersion from the build clock. Homebrew needs a
# monotonic, unique version per release, so the release workflow derives
# <VERSION>.<YYYYMMDD>.<run_number> and this script stamps that same string
# into the bundle so the About box / MCP serverInfo.version match the cask.
# Editing Info.plist invalidates the signature, hence the signing after it.
#
# Why this signature (docs/releasing.md): macOS files a person's grants — Full
# Disk Access, Files & Folders, Automation — and a keychain item's "Always
# Allow" under the app's designated requirement. Ad hoc, that requirement is
# the hash of this one build, so every update dropped them all. Signed with the
# explicit requirement in release/designated-requirement.txt (Copper's
# identifier and any Developer ID of Copper's team), every release satisfies
# the same requirement and the grants carry over, through a renewed
# certificate too. Gatekeeper opens a notarized app with the hardened runtime
# and a secure timestamp, and the entitlements in Copper.entitlements are what
# the runtime would otherwise refuse (camera, microphone, calendars, location,
# Apple Events). The identity is the certificate's SHA-1, so a secret that
# holds any other certificate fails here.
#
# Without COPPER_SIGN_IDENTITY the bundle is signed ad hoc and not notarized,
# for trying this script out; the release workflow refuses to publish such a
# bundle.
set -euo pipefail

app="${1:?usage: package-app.sh <Copper.app> <version> <out-dir>}"
version="${2:?version}"
out="${3:?out-dir}"
arch="${4:-arm64}"
here="$(cd "$(dirname "$0")" && pwd)"

[ -d "$app/Contents" ] || { echo "not an app bundle: $app" >&2; exit 1; }
case "$version" in
  [0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
  *) echo "version must look like 1.0.20260924.3, got: $version" >&2; exit 1 ;;
esac
case "$arch" in
  arm64 | x86_64) ;;
  *) echo "arch must be arm64 or x86_64, got: $arch" >&2; exit 1 ;;
esac
# The zip's name promises a CPU; the binary inside has to keep it.
built="$(lipo -archs "$app/Contents/MacOS/Copper")"
[ "$built" = "$arch" ] || { echo "$app is built for $built, not $arch" >&2; exit 1; }

plist="$app/Contents/Info.plist"
requirement="$(tr -d '\n' < "$here/designated-requirement.txt")"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"

identity="${COPPER_SIGN_IDENTITY:-}"
if [ -n "$identity" ]; then
  # A release is Copper itself; a development build (com.collinrijock.copper.dev,
  # build.sh without COPPER_RELEASE=1) would sign fine and then never satisfy
  # the requirement — or replace anyone's Copper.
  case "$requirement" in
    *"identifier \"$bundle_id\" "*) ;;
    *) echo "bundle id $bundle_id is not the release's ($requirement) — build with COPPER_RELEASE=1" >&2; exit 1 ;;
  esac
  # The updater inside checks every later release against the same team
  # (Fork/Signing.swift). A bundle that pins another one would refuse the
  # next update, so it is not signed at all.
  team="$(printf '%s' "$requirement" | sed -n 's/.*certificate leaf\[subject\.OU\] = "\([0-9A-Z]*\)".*/\1/p')"
  [ -n "$team" ] || { echo "no team (certificate leaf[subject.OU]) in designated-requirement.txt" >&2; exit 1; }
  if ! LC_ALL=C grep -a -q -F "certificate leaf[subject.OU] = \"$team\"" "$app/Contents/MacOS/Copper"; then
    echo "the app's updater does not pin team $team (Fork/Signing.swift) — refusing to sign it for that team" >&2
    exit 1
  fi
  # A Developer ID release that isn't notarized is one Gatekeeper refuses.
  for var in COPPER_NOTARY_KEY COPPER_NOTARY_KEY_ID COPPER_NOTARY_ISSUER; do
    [ -n "${!var:-}" ] || { echo "$var is not set: a Developer ID release is notarized (docs/releasing.md)" >&2; exit 1; }
  done
  keychain=()
  if [ -n "${COPPER_SIGN_KEYCHAIN:-}" ]; then keychain=(--keychain "$COPPER_SIGN_KEYCHAIN"); fi
  # Inside out: anything nested (nothing today) with the identity, then the
  # app itself with the entitlements and the explicit requirement — given to
  # --deep, they would be stamped on nested code they don't describe.
  codesign --force --deep --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app"
  codesign --force --options runtime --timestamp --entitlements "$here/../Copper.entitlements" \
    --sign "$identity" ${keychain[@]+"${keychain[@]}"} -r="designated => $requirement" "$app"
  codesign --verify --deep --strict -R="$requirement" "$app"
  echo "signed  $(codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => /designated => /p')" >&2
else
  # Why --deep: the bundle has no nested frameworks today, but a future build
  # might; --deep keeps the whole tree consistently ad-hoc signed either way.
  codesign --force --deep --sign - "$app"
  codesign --verify --deep --strict "$app"
  echo "signed  ad hoc (no COPPER_SIGN_IDENTITY) — not a release" >&2
fi

if [ -x "$app/Contents/Resources/bin/copper" ]; then has_cli=true; else has_cli=false; fi

mkdir -p "$out"
zip="$out/copper-${version}-macos-${arch}.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --keepParent "$app" "$zip"
if [ -n "$identity" ]; then
  # Apple's notary service looks the zip over; its ticket is stapled to the
  # app, so Gatekeeper accepts it offline too, and the zip is made again
  # around the stapled app.
  notary="$(mktemp -d)"
  trap 'rm -rf "$notary"' EXIT
  xcrun notarytool submit "$zip" --key "$COPPER_NOTARY_KEY" --key-id "$COPPER_NOTARY_KEY_ID" \
    --issuer "$COPPER_NOTARY_ISSUER" --wait --timeout 45m --output-format json > "$notary/submit.json" || true
  status="$(plutil -extract status raw -o - "$notary/submit.json" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$notary/submit.json" 2>/dev/null || true)"
  echo "notary  $arch: ${status:-no answer} (${id:-no id})" >&2
  if [ "$status" != Accepted ]; then
    cat "$notary/submit.json" >&2
    [ -z "$id" ] || xcrun notarytool log "$id" --key "$COPPER_NOTARY_KEY" --key-id "$COPPER_NOTARY_KEY_ID" \
      --issuer "$COPPER_NOTARY_ISSUER" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$app" >&2
  xcrun stapler validate "$app" >&2
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
fi
( cd "$out" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256" )

echo "stamped $(plutil -extract CFBundleShortVersionString raw -o - "$plist") (build $(plutil -extract CFBundleVersion raw -o - "$plist"))" >&2
echo "packed  $zip ($(du -h "$zip" | cut -f1))" >&2
echo "has_cli=$has_cli"
