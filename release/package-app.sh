#!/bin/bash
# Stamp the release version into a built Copper.app, sign it with Copper's
# release certificate, and zip it.
#
#   COPPER_SIGN_IDENTITY=<sha1> [COPPER_SIGN_KEYCHAIN=<path>] \
#     release/package-app.sh <path/to/Copper.app> <version> <out-dir> [arm64|x86_64]
#
# Writes to <out-dir>, for <arch> (default arm64, the CPU the binary must be):
#   copper-<version>-macos-<arch>.zip          ditto --keepParent archive
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
# one certificate in release/ and the explicit requirement in
# release/designated-requirement.txt, every release satisfies the same
# requirement and the grants carry over. The identity is that certificate's
# SHA-1, so a secret that holds any other certificate fails here. Flags and
# entitlements are what they were ad hoc: none (no hardened runtime).
#
# Without COPPER_SIGN_IDENTITY the bundle is signed ad hoc, for trying this
# script out; the release workflow refuses to publish such a bundle.
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
  # The updater inside checks every later release against the same
  # certificate (Fork/Signing.swift). A bundle that pins another one would
  # refuse the next update, so it is not signed at all.
  leaf="$(printf '%s' "$requirement" | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p')"
  [ -n "$leaf" ] || { echo "no certificate leaf hash in designated-requirement.txt" >&2; exit 1; }
  if ! LC_ALL=C grep -a -q -F "$leaf" "$app/Contents/MacOS/Copper"; then
    echo "the app's updater does not pin $leaf (Fork/Signing.swift) — refusing to sign it with that certificate" >&2
    exit 1
  fi
  keychain=()
  if [ -n "${COPPER_SIGN_KEYCHAIN:-}" ]; then keychain=(--keychain "$COPPER_SIGN_KEYCHAIN"); fi
  # Inside out: anything nested (nothing today) with the identity, then the
  # app itself with the explicit requirement — given to --deep, the
  # requirement would be stamped on nested code it can't describe.
  codesign --force --deep --timestamp=none --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app"
  codesign --force --timestamp=none --sign "$identity" ${keychain[@]+"${keychain[@]}"} \
    -r="designated => $requirement" "$app"
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
( cd "$out" && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256" )

echo "stamped $(plutil -extract CFBundleShortVersionString raw -o - "$plist") (build $(plutil -extract CFBundleVersion raw -o - "$plist"))" >&2
echo "packed  $zip ($(du -h "$zip" | cut -f1))" >&2
echo "has_cli=$has_cli"
