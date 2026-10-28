#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary — and, when
# asked, the disk image people install it from and the ZIP the updater
# fetches.
#
#   ./build.sh                 debug-free release build, ad-hoc signed: runs here,
#                                as the development app (com.collinrijock.copper.dev)
#   COPPER_RELEASE=1 ./build.sh release app
#                              the same, as Copper itself (com.collinrijock.copper):
#                                what .github/workflows/release.yml builds and then
#                                signs with Copper's release certificate
#   ./build.sh release dmg     + build/Copper.dmg, build/Copper.zip and
#                                build/appcast.json, signed with Developer ID
#                                if there is one in the keychain
#   ./build.sh release ship    + both notarised, the DMG stapled
#   COPPER_ARCH=x86_64 ./build.sh release app
#                              the Intel app, cross-built on Apple Silicon, in
#                                build/x86_64/ beside the arm64 one: a release
#                                carries both (.github/workflows/release.yml)
#
# Same shape as the one next door: SwiftPM builds the executable, and a macOS
# app bundle is just a folder with a plist and the binary in the right place.
#
# The three files keep the same names from release to release, so the site
# links to them once and the updater reads one address forever. ./publish.sh
# copies them into the site.
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
#
# What "ship" needs, once:
#   - a Developer ID Application certificate in the login keychain
#     (SEARCH_SIGN_IDENTITY names it; otherwise the first one found is used)
#   - a notarytool profile: xcrun notarytool store-credentials "search"
#     (SEARCH_NOTARY_PROFILE names it; default "search")
#   - SEARCH_DOWNLOAD_URL, the https folder the three files are served from,
#     for the appcast. Default https://officecommun.com/search, which is
#     where Updater.feed in Updater.swift looks.
#
# NOTES.md, next to this script, is what's new: newest release first, one
# paragraph each. The first paragraph goes into the appcast, and from there
# under the version line in Settings.
#
# Which app it is (docs/releasing.md). macOS files privacy grants (Full Disk
# Access, Files & Folders, Automation), the defaults domain, WebKit's data
# container and keychain access under the bundle id. A build from a worktree
# that called itself com.collinrijock.copper overwrote the installed Copper's
# grants and shared its cookies and settings, so only a release says it is
# Copper: COPPER_RELEASE=1, or the dmg and ship steps, which only exist to
# hand Copper out. Everything else is com.collinrijock.copper.dev, which Copper
# runs as a test world of its own (Store.swift) and which leaves copper://
# links to the installed app.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Copper.app"
# Fork (intel): another CPU's app gets a folder of its own, so building it
# never replaces this Mac's. Only the app step: the disk image, the ZIP and
# the appcast are this Mac's alone.
ARCH="${COPPER_ARCH:-}"
if [ -n "$ARCH" ]; then
  [ "$STEP" = app ] || { echo "COPPER_ARCH builds the app step only" >&2; exit 1; }
  APP="build/$ARCH/Copper.app"
fi
NAME="Copper"
VERSION="$(tr -d '[:space:]' < VERSION)"
# A build number that only ever goes up, so the updater can tell newer from
# older without parsing version strings.
BUILD="$(date +%Y%m%d%H%M)"
# The oldest macOS this runs on — in the plist, and in the appcast so an
# older Mac is not handed a build it can't open.
MINIMUM="14.0"
if [ "${COPPER_RELEASE:-}" = 1 ] || [ "$STEP" = dmg ] || [ "$STEP" = ship ]; then
  BUNDLE_ID="com.collinrijock.copper"
  # copper:// canvas links, from another app, go to the installed Copper only.
  COPPER_SCHEME='
    <dict>
      <key>CFBundleURLName</key><string>Copper link</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array><string>copper</string></array>
    </dict>'
else
  BUNDLE_ID="com.collinrijock.copper.dev"
  COPPER_SCHEME=""
fi

# Fork (canvas): the canvas page is built next door (Canvas/, bun + Vite) to
# one self-contained file; a newer build of it replaces the copy the app
# carries. No bun here is fine — the committed copy is used as it is.
CANVAS_PAGE="Sources/Search/Fork/Canvas/Resources/canvas.html"
if [ -f Canvas/dist/canvas.html ] && [ Canvas/dist/canvas.html -nt "$CANVAS_PAGE" ]; then
  cp Canvas/dist/canvas.html "$CANVAS_PAGE"
fi

if [ -n "$ARCH" ]; then
  # The oldest macOS goes into the triple too, as it is in the plist.
  swift build -c "$CONFIG" --triple "$ARCH-apple-macosx$MINIMUM"
  PRODUCTS=".build/$ARCH-apple-macosx/$CONFIG"
else
  swift build -c "$CONFIG"
  PRODUCTS=".build/$CONFIG"
fi
BINARY="$PRODUCTS/Search"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Resources/bin"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
cp bin/copper "$APP/Contents/Resources/bin/copper"
chmod 755 "$APP/Contents/Resources/bin/copper"
# SwiftPM's resource bundle (the animated backdrop's page and three.js),
# under the name Bundle.module and Fork/AnimatedBackdrop.swift both look for.
if [ -d "$PRODUCTS/Search_Search.bundle" ]; then
  cp -R "$PRODUCTS/Search_Search.bundle" "$APP/Contents/Resources/"
fi
# Fork (voice): the vendored speech runner's Apache-2.0 LICENSE and NOTICE
# travel with the binary it is compiled into (Settings › Voice credits it).
mkdir -p "$APP/Contents/Resources/phonon-coreml"
cp Sources/Search/Fork/Voice/Phonon/LICENSE Sources/Search/Fork/Voice/Phonon/NOTICE "$APP/Contents/Resources/phonon-coreml/"

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary — 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -o build/Copper.app.dSYM/Contents/Resources/DWARF/Search).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BINARY" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
fi

# The icon, drawn fresh each time — it is thirty lines of Swift, not an asset
# to keep in step with anything.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Icon/icon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© Collin Rijock and Felipe Arce. Built on Search by Office Commun.</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Owning http and https is what lets macOS offer this app as the default
       browser, and what sends a link clicked in Mail here. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>$COPPER_SCHEME
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A browser is asked for these by the pages it shows; the microphone is
       also dictation's, in the agent pane (docs/voice.md). macOS still wants a
       sentence to put in its own prompt, and touching the APIs without one is
       a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Copper asks you first, every time, for each site.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Copper uses your microphone when you dictate to the agent, and when a website you allow asks for it. Speech is turned into text on this Mac.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

# Signing. A Developer ID certificate, when there is one, with the hardened
# runtime Gatekeeper insists on for anything notarised; otherwise ad-hoc,
# which is enough for the app to run on the machine that built it — and
# which the updater refuses to swap anything in under. A release is signed
# again afterwards, with Copper's own certificate and a designated requirement
# that stays the same from release to release (release/package-app.sh).
IDENTITY="${SEARCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
# Passkeys need an entitlement Apple grants to browsers on request, and a
# Developer ID provisioning profile that carries it. With the profile next to
# this script, both go in; without it, the app is signed as before, because
# a restricted entitlement with no profile behind it is an app that won't open.
ENTITLEMENTS="Search.entitlements"
if [ -f "Search.provisionprofile" ]; then
  cp "Search.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="Search.passkeys.entitlements"
  echo "passkeys: profile embedded"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  [ "$STEP" != "app" ] && echo "no Developer ID certificate found — the DMG will only open on this Mac" >&2
fi

echo "built: $APP ($VERSION, build $BUILD, $BUNDLE_ID)"
[ "$STEP" = "app" ] && exit 0

# The disk image: the app beside a shortcut to Applications, on a white
# window with an arrow between them — drawn by Installer/background.swift and
# laid out by Installer/dmg.py through dmgbuild, which writes the Finder's
# layout file itself, so no Finder is scripted and no window opens mid-build.
# dmgbuild is installed into .build the first time, and needs Python 3 and a
# network then; without it the image is the plain one it always was.
DMG="build/$NAME.dmg"
ART="build/installer"
rm -rf "$ART" "$DMG"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [ -x "$DMGBUILD" ] \
  && swift Installer/background.swift "$ART" >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D app="$APP" -D background="$ART/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild — a plain disk image, without its window laid out" >&2
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
fi
rm -rf "$ART"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "packed: $DMG"

# The ZIP is what the updater fetches, and its hash is what the updater
# checks before opening it.
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "packed: $ZIP"

# What the updater reads. The first paragraph of NOTES.md, with the two
# characters JSON minds escaped, is the line under the version in Settings.
BASE="${SEARCH_DOWNLOAD_URL:-https://officecommun.com/search}"
BASE="${BASE%/}"
NOTES=""
if [ -f NOTES.md ]; then
  NOTES="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
fi
cat > build/appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$BASE/$NAME.zip",
  "dmg": "$BASE/$NAME.dmg",
  "sha256": "$SHA",
  "notes": "$NOTES",
  "minimumSystemVersion": "$MINIMUM"
}
JSON
echo "wrote: build/appcast.json ($VERSION, build $BUILD)"
[ "$STEP" = "dmg" ] && exit 0

# Notarisation: Apple looks both over. The ticket is stapled to the image,
# so it opens on a Mac that has never seen this app and is offline; the ZIP
# is fetched by an app that already trusts it, and is left as hashed.
[ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate" >&2; exit 1; }
for FILE in "$DMG" "$ZIP"; do
  xcrun notarytool submit "$FILE" --keychain-profile "${SEARCH_NOTARY_PROFILE:-search}" --wait
done
xcrun stapler staple "$DMG"
echo "shipped: $DMG, $ZIP and build/appcast.json — ./publish.sh <folder> puts them on the site"
