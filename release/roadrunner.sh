#!/usr/bin/env bash
# The Copper release on Roadrunner's Mac (.woodpecker/release.yaml; docs/releasing.md).
# Builds arm64 + x86_64 (Intel, cross-built), signs both with Copper's own certificate, checks the
# signatures and publishes a GitHub release of this repo:
#   COPPER_RELEASE=publish|dry-run [COPPER_PRERELEASE=true] bash release/roadrunner.sh
# dry-run builds, signs and checks the same way and publishes nothing (no tag, no release).
# Secrets: COPPER_SIGNING_P12_BASE64, COPPER_SIGNING_P12_PASSWORD, GH_TOKEN (publish only).
set -euo pipefail
cd "$(dirname "$0")/.."
repo=copper-browser/Copper
mode="${COPPER_RELEASE:-}"
case "$mode" in publish | dry-run) ;; *) echo "COPPER_RELEASE must be publish or dry-run" >&2; exit 1 ;; esac
branch="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
# A real release is built from fork only; dry runs may build any branch.
if [ "$mode" = publish ] && [ "$branch" != fork ]; then
  echo "publish builds from fork only, not '$branch'. Use COPPER_RELEASE=dry-run for another branch." >&2
  exit 1
fi
tmp="$(mktemp -d)"
keychain="$tmp/copper-signing.keychain-db"
cleanup() {
  [ ! -e "$keychain" ] || security delete-keychain "$keychain" || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Version: <VERSION file>.<YYYYMMDD>.<n>, n = one past today's highest released n (monotonic for
# Homebrew and the updater; GitHub Actions used its run number).
commit="$(git rev-parse HEAD)"
base="$(tr -d '[:space:]' < VERSION)"
day="$(date -u +%Y%m%d)"
last="$(git ls-remote --tags "https://github.com/$repo.git" "v$base.$day.*" | sed -n 's|.*refs/tags/v.*\.\([0-9][0-9]*\)$|\1|p' | sort -n | tail -1)"
version="$base.$day.$(( ${last:-0} + 1 ))"
tag="v$version"
zip_name="copper-$version-macos-arm64.zip"
x86_64_zip_name="copper-$version-macos-x86_64.zip"
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Building $repo@$commit as Copper $version ($mode)"
xcodebuild -version || true
swift --version

# Build: Copper's own bundle id (COPPER_RELEASE=1); build.sh's own signature is ad hoc and
# package-app.sh signs the release.
COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY="" ./build.sh release app
test -d build/Copper.app/Contents/MacOS
test "$(plutil -extract CFBundleIdentifier raw -o - build/Copper.app/Contents/Info.plist)" = com.collinrijock.copper
swift test --filter xosInsert
COPPER_RELEASE=1 COPPER_ARCH=x86_64 SEARCH_SIGN_IDENTITY="" ./build.sh release app
test "$(lipo -archs build/x86_64/Copper.app/Contents/MacOS/Copper)" = x86_64
diff <(ls build/Copper.app/Contents/Resources) <(ls build/x86_64/Copper.app/Contents/Resources)
test -d build/x86_64/Copper.app/Contents/Resources/Search_Search.bundle
test "$(plutil -extract CFBundleIdentifier raw -o - build/x86_64/Copper.app/Contents/Info.plist)" = com.collinrijock.copper

# Signing keychain, for this run only.
if [ -z "${COPPER_SIGNING_P12_BASE64:-}" ] || [ -z "${COPPER_SIGNING_P12_PASSWORD:-}" ]; then
  echo "COPPER_SIGNING_P12_BASE64 / COPPER_SIGNING_P12_PASSWORD are not set. A release is never ad-hoc signed (docs/releasing.md)." >&2
  exit 1
fi
(
  umask 077
  p12="$tmp/copper-signing.p12"
  pass="$(openssl rand -hex 24)"
  printf '%s' "$COPPER_SIGNING_P12_BASE64" | base64 --decode > "$p12"
  security create-keychain -p "$pass" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$pass" "$keychain"
  security import "$p12" -k "$keychain" -f pkcs12 -P "$COPPER_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
  rm -f "$p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$keychain" >/dev/null
  # shellcheck disable=SC2046 # the search list is a list of words
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
)
want="$(shasum -a 1 release/copper-release-signing.cer | cut -d' ' -f1)"
grep -q "certificate leaf = H\"${want}\"" release/designated-requirement.txt ||
  { echo "release/designated-requirement.txt does not name release/copper-release-signing.cer ($want)" >&2; exit 1; }
case "$(security find-identity -p codesigning "$keychain" | tr 'A-F' 'a-f')" in
  *"$want"*) ;;
  *) echo "the signing secret does not hold the certificate release/ pins ($want). Rotating? See docs/releasing.md." >&2; exit 1 ;;
esac
echo "signing identity $want (Copper Release Signing) in a keychain of this run only"

# Stamp version, sign, zip.
out="$tmp/upload"
has_cli="$(COPPER_SIGN_IDENTITY="$want" COPPER_SIGN_KEYCHAIN="$keychain" \
  bash release/package-app.sh build/Copper.app "$version" "$out" arm64 | sed -n 's/^has_cli=//p')"
sha256="$(cut -d' ' -f1 < "$out/$zip_name.sha256")"
cp "$out/$zip_name" "$out/copper-macos-arm64.zip"
printf '%s  copper-macos-arm64.zip\n' "$sha256" > "$out/copper-macos-arm64.zip.sha256"
COPPER_SIGN_IDENTITY="$want" COPPER_SIGN_KEYCHAIN="$keychain" \
  bash release/package-app.sh build/x86_64/Copper.app "$version" "$out" x86_64 > /dev/null
x86_64_sha256="$(cut -d' ' -f1 < "$out/$x86_64_zip_name.sha256")"
cp "$out/$x86_64_zip_name" "$out/copper-macos-x86_64.zip"
printf '%s  copper-macos-x86_64.zip\n' "$x86_64_sha256" > "$out/copper-macos-x86_64.zip.sha256"
cp release/copper-install.sh "$out/copper-install.sh"
security delete-keychain "$keychain" || true

# Check the signature of the shipped zips.
req="$(tr -d '\n' < release/designated-requirement.txt)"
for arch in arm64 x86_64; do
  echo "--- $arch"
  check="$tmp/check-$arch"
  mkdir -p "$check"
  ditto -x -k "$out/copper-$version-macos-$arch.zip" "$check"
  app="$check/Copper.app"
  test "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = com.collinrijock.copper
  test "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version"
  test "$(lipo -archs "$app/Contents/MacOS/Copper")" = "$arch"
  dr="$(codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => //p')"
  echo "designated => $dr"
  [ "$dr" = "$req" ] || { echo "$arch: designated requirement is '$dr', expected '$req'" >&2; exit 1; }
  codesign --verify --deep --strict "$app"
  codesign --verify --deep --strict -R="$req" "$app"
  entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null || true)"
  [ -z "$entitlements" ] || { echo "$arch: entitlements appeared; releases carry none" >&2; exit 1; }
done

# dSYM per CPU, only when its UUID is the shipped binary's.
for arch in arm64 x86_64; do
  app=build/Copper.app
  [ "$arch" = arm64 ] || app="build/$arch/Copper.app"
  dsym="$app.dSYM"
  [ -d "$dsym" ] || { echo "warning: no $dsym, this release's $arch crash reports won't symbolicate"; continue; }
  app_uuid="$(dwarfdump --uuid "$app/Contents/MacOS/Copper" | awk '{print $2}')"
  dsym_uuid="$(dwarfdump --uuid "$dsym" | awk '{print $2}')"
  if [ -z "$app_uuid" ] || [ "$app_uuid" != "$dsym_uuid" ]; then
    echo "warning: $arch dSYM UUID $dsym_uuid is not the binary's $app_uuid; not attaching it"
    continue
  fi
  ditto -c -k --keepParent "$dsym" "$out/copper-$version-macos-$arch.dSYM.zip"
done

# shellcheck disable=SC2016 # the node script is single-quoted on purpose
# copper-version.json: the updater's and the tap's manifest (same shape as before).
OUT="$out" VERSION="$version" TAG="$tag" COMMIT="$commit" SHA256="$sha256" ZIP_NAME="$zip_name" \
X86_64_SHA256="$x86_64_sha256" X86_64_ZIP_NAME="$x86_64_zip_name" HAS_CLI="$has_cli" \
PUBLISHED_AT="$published_at" REPO="$repo" node -e '
  const fs = require("fs");
  const e = process.env;
  const base = `https://github.com/${e.REPO}/releases`;
  let notes = "";
  try {
    const first = fs.readFileSync("NOTES.md", "utf8").split(/\n\s*\n/).find((p) => p.trim());
    notes = (first || "").split("\n").map((l) => l.trim()).filter(Boolean).join(" ");
  } catch {}
  const manifest = {
    schemaVersion: 1,
    product: "copper",
    version: e.VERSION,
    releaseId: e.TAG,
    commit: e.COMMIT,
    source: `https://github.com/${e.REPO}/commit/${e.COMMIT}`,
    status: "lkg",
    publishedAt: e.PUBLISHED_AT,
    arch: "arm64",
    zip: e.ZIP_NAME,
    sha256: e.SHA256,
    hasCli: e.HAS_CLI === "true",
    archiveUrl: `${base}/download/${e.TAG}/${e.ZIP_NAME}`,
    latestUrl: `${base}/latest/download/copper-macos-arm64.zip`,
    archives: {
      arm64: {
        zip: e.ZIP_NAME,
        sha256: e.SHA256,
        archiveUrl: `${base}/download/${e.TAG}/${e.ZIP_NAME}`,
        latestUrl: `${base}/latest/download/copper-macos-arm64.zip`,
      },
      x86_64: {
        zip: e.X86_64_ZIP_NAME,
        sha256: e.X86_64_SHA256,
        archiveUrl: `${base}/download/${e.TAG}/${e.X86_64_ZIP_NAME}`,
        latestUrl: `${base}/latest/download/copper-macos-x86_64.zip`,
      },
    },
    installer: "copper-install.sh",
    notes,
  };
  fs.writeFileSync(`${e.OUT}/copper-version.json`, JSON.stringify(manifest, null, 2) + "\n");
'
cat "$out/copper-version.json"
(cd "$out" && shasum -a 256 ./*)

if [ "$mode" != publish ]; then
  echo "dry run: Copper $version built, signed and checked; nothing published (no tag, no release)"
  exit 0
fi

: "${GH_TOKEN:?GH_TOKEN must be set to publish}"
notes="$tmp/notes.md"
cat > "$notes" <<EOF
Copper ${version} — built from ${repo}@${commit:0:12}.

**Install**

\`\`\`sh
brew install --cask copper-browser/copper/copper
\`\`\`

or

\`\`\`sh
curl -fsSL https://github.com/${repo}/releases/latest/download/copper-install.sh | sh
\`\`\`

or download the zip for your Mac below — \`${zip_name}\` for Apple Silicon, \`${x86_64_zip_name}\` for Intel — unzip, move Copper.app to /Applications and run \`xattr -cr /Applications/Copper.app\` once (signed with Copper's own certificate, not notarized).

macOS 14 Sonoma or later, Apple Silicon or Intel. Already installed? Copper updates itself — Settings › Updates.

sha256 \`${sha256}\` (arm64)
sha256 \`${x86_64_sha256}\` (x86_64)
EOF
flags=(--latest)
[ "${COPPER_PRERELEASE:-}" = true ] && flags=(--prerelease --latest=false)
dsym_zips=()
for arch in arm64 x86_64; do
  [ -f "$out/copper-$version-macos-$arch.dSYM.zip" ] && dsym_zips+=("$out/copper-$version-macos-$arch.dSYM.zip")
done
GH_PROMPT_DISABLED=1 gh release create "$tag" \
  --repo "$repo" \
  --target "$commit" \
  --title "Copper $version" \
  --notes-file "$notes" \
  "${flags[@]}" \
  "$out/$zip_name" "$out/$zip_name.sha256" \
  "$out/copper-macos-arm64.zip" "$out/copper-macos-arm64.zip.sha256" \
  "$out/$x86_64_zip_name" "$out/$x86_64_zip_name.sha256" \
  "$out/copper-macos-x86_64.zip" "$out/copper-macos-x86_64.zip.sha256" \
  "$out/copper-version.json" "$out/copper-install.sh" \
  ${dsym_zips[@]+"${dsym_zips[@]}"}

# Verify the published bytes.
for pair in "$zip_name=$sha256" "$x86_64_zip_name=$x86_64_sha256"; do
  name="${pair%%=*}"
  want_sha="${pair#*=}"
  url="https://github.com/$repo/releases/download/$tag/$name"
  curl -fsSL --retry 5 --retry-delay 3 --max-time 600 -o "$tmp/verify.zip" "$url"
  actual="$(shasum -a 256 "$tmp/verify.zip" | cut -d' ' -f1)"
  [ "$actual" = "$want_sha" ] || { echo "$url serves $actual, expected $want_sha" >&2; exit 1; }
  echo "OK $url"
done
echo "released https://github.com/$repo/releases/tag/$tag (the tap picks it up on its next hourly bump)"
