#!/bin/bash
# Cut a Copper release from Felipe's laptop, without GitHub Actions: build on
# his Mac mini, sign here, check, launch, publish.
#
#   release/release-local.sh --dry-run          everything but the tag, the release and the upload
#   release/release-local.sh                    publish fork's HEAD as the next version
#   release/release-local.sh --version 1.0.20261111.106 [--dry-run]
#   release/release-local.sh --preflight        only the checks before the build
#
#   COPPER_RELEASE_REMOTE_DIR='~/farm/copper-release' release/release-local.sh …
#                                               build in another folder on the mini
#                                               (default: its external disk)
#
# What it makes is what .github/workflows/release.yml makes — the same build
# commands and checks, the same signature (Copper's own certificate and the
# requirement in release/designated-requirement.txt), the same assets, the same
# copper-version.json and the same release text — so the updater, the curl
# installer and the Homebrew tap can't tell which path cut a release. The
# workflow still exists for Collin's runner; this is the path that uses no
# GitHub Actions at all (docs/releasing.md › Cutting a release without GitHub
# Actions).
#
# Where each part runs, and why:
#   - The laptop: preflight, version, signing, packaging, publishing. The
#     signing key (~/.config/copper-signing, 0600) never leaves it, and no
#     keychain is involved anywhere: rcodesign reads the p12 itself.
#   - The Mac mini (MINI below): both builds, the Xos test and the launch
#     check. It has the full Xcode, Rosetta and the cores; the job folder
#     (REMOTE_DIR below) is deleted at the end, whatever happened.
#
# The version is <VERSION file>.<UTC YYYYMMDD>.<n>, n one more than the highest
# trailing number of any v… tag or release in copper-browser/Copper. The
# workflow's n is its run number, so both paths share one sequence: a local
# release never takes a number the workflow already used, or sorts below one.
#
# Writes build/release-local/<version>/ (gitignored): assets/ is exactly what
# a release uploads, release-notes.md its text, logs/ the build and sign logs.
set -euo pipefail

REPO=copper-browser/Copper
MINI=felipe-exowatt@100.112.175.26
# Where the job folder goes on the mini: the external disk, since the internal
# one is nearly full. When the external one is full instead, point this at
# '~/farm/copper-release' (the internal disk, quoted so ~ is the mini's) for the run.
REMOTE_DIR="${COPPER_RELEASE_REMOTE_DIR:-/Volumes/Farm/farm-exowatt/copper-release}"
# Free space the job wants there. The build compiles three configurations
# (arm64 release, the debug build swift test needs, x86_64 release), each
# about 1 GB of .build on the mini, plus the sources and the two apps with
# their dSYMs: about 3.5 GB. The build reports what it used.
REMOTE_FREE_GB=5
SIGNING=$HOME/.config/copper-signing
P12=$SIGNING/copper-release-signing.p12
P12_PASSWORD=$SIGNING/p12-password
# rcodesign (apple-codesign), pinned: the tarball's SHA-256 as the project
# publishes it, and the binary inside it.
RCODESIGN_VERSION=0.29.0
RCODESIGN_TARBALL=apple-codesign-$RCODESIGN_VERSION-macos-universal.tar.gz
RCODESIGN_TARBALL_SHA256=d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d
RCODESIGN_SHA256=75ef370d4de9fc99d8b26a168bed9c256da8364d8b9fdb2be762ab42fc6a9978
RCODESIGN_URL=https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$RCODESIGN_VERSION/$RCODESIGN_TARBALL

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }
step() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'release-local: %s\n' "$*" >&2; exit 1; }

dry_run=false
preflight=false
version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --preflight) preflight=true; dry_run=true ;;
    --version) version="${2:?--version needs a value}"; shift ;;
    --version=*) version="${1#*=}" ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
root="$(pwd)"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
# Every call to the mini has a deadline, so a dropped connection is an error
# and not a terminal waiting forever.
mini() { local seconds="$1"; shift; timeout "$seconds" ssh "${ssh_opts[@]}" "$MINI" "$@"; }

# ---------------------------------------------------------------------------
step "Preflight"

for tool in git gh node curl shasum ditto codesign csreq plutil lipo dwarfdump tar timeout ssh; do
  command -v "$tool" > /dev/null || fail "needs $tool on PATH"
done
gh auth status > /dev/null 2>&1 || fail "gh is not signed in (gh auth login)"

commit="$(git rev-parse HEAD)"
fork_head="$(gh api "repos/$REPO/branches/fork" --jq .commit.sha)"
dirty="$(git status --porcelain)"
note "commit   $commit"
note "fork     $fork_head ($REPO)"
# A release is fork's HEAD, built from a tree that is exactly that commit —
# the workflow publishes from fork only, too. The build itself is
# `git archive <commit>`, so a dry run of a dirty tree still builds only what
# is committed; it says so.
if [ "$commit" != "$fork_head" ]; then
  $dry_run || fail "HEAD is not $REPO fork's HEAD ($fork_head); a release is built from fork only"
  note "dry run of a commit that is not fork's HEAD"
fi
if [ -n "$dirty" ]; then
  $dry_run || fail "the working tree has uncommitted changes; a release is built from a clean tree"
  note "dry run: uncommitted changes are not in the build (it is $(git rev-parse --short=12 HEAD) as committed)"
fi

# The key and its password: present, and private to this account. Never
# printed, copied or sent anywhere; rcodesign reads both where they are.
for secret in "$P12" "$P12_PASSWORD"; do
  [ -f "$secret" ] || fail "missing $secret (docs/releasing.md › Keeping the key)"
  mode="$(stat -f %Lp "$secret")"
  [ "$mode" = 600 ] || fail "$secret is mode $mode; it must be 0600"
done

requirement="$(git show "$commit:release/designated-requirement.txt" | tr -d '\n')"
# The requirement names the certificate in release/ (hashes are public).
want="$(git show "$commit:release/copper-release-signing.cer" | shasum -a 1 | cut -d' ' -f1)"
case "$requirement" in
  *"certificate leaf = H\"$want\""*) ;;
  *) fail "release/designated-requirement.txt does not name release/copper-release-signing.cer ($want)" ;;
esac

# Every tag and release name in the repository, drafts included.
existing="$(
  {
    gh api --paginate "repos/$REPO/tags?per_page=100" --jq '.[].name'
    gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].tag_name'
  } | sed -n -E 's/^v([0-9]+\.[0-9]+\.[0-9]{8}\.[0-9]+)$/\1/p' | sort -u -V
)"
latest="$(printf '%s\n' "$existing" | tail -1)"
highest="$(printf '%s\n' "$existing" | sed -E 's/.*\.//' | sort -n | tail -1)"
if [ -z "$version" ]; then
  base="$(git show "$commit:VERSION" | tr -d '[:space:]')"
  version="${base}.$(date -u +%Y%m%d).$((${highest:-0} + 1))"
else
  case "$version" in
    [0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
    *) fail "version must look like 1.0.20260924.3, got: $version" ;;
  esac
fi
tag="v$version"
if printf '%s\n' "$existing" | grep -qxF "$version"; then
  fail "$tag already exists in $REPO"
fi
# The updater, the installer and the tap only ever move forward.
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
  $dry_run || fail "$version does not sort above the latest release, $latest"
  note "dry run: $version sorts below the latest release, $latest"
fi
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
zip_name="copper-${version}-macos-arm64.zip"
x86_64_zip_name="copper-${version}-macos-x86_64.zip"
note "version  $version ($tag; latest is ${latest:-none})"
if $preflight; then
  note "mode     preflight: the checks only, nothing is built"
elif $dry_run; then
  note "mode     dry run: nothing is tagged, released or uploaded"
else
  note "mode     PUBLISH"
fi

out="$root/build/release-local/$version"
assets="$out/assets"
logs="$out/logs"
work="$(mktemp -d "${TMPDIR:-/tmp}/copper-release.XXXXXX")"
job=""
on_mini=false

# Whatever happens: nothing of ours keeps running on the mini, its job folder
# and the throwaway worlds go, and so does the scratch folder here.
cleanup() {
  local status=$?
  set +e
  if $on_mini; then
    mini 300 bash -s -- "$job" > /dev/null 2>&1 <<'REMOTE'
job="$1"
check="$(cat "$job/check-dir" 2> /dev/null)"
if [ -f "$job/labels" ]; then
  while read -r label; do
    [ -n "$label" ] && launchctl bootout "gui/$(id -u)/$label" 2> /dev/null
  done < "$job/labels"
fi
# Only processes started from this job's folders: the apps the launch check opened.
ours() {
  case "$1" in "$job"/*) return 0 ;; esac
  [ -n "$check" ] || return 1
  case "$1" in "$check"/* | "/private$check"/*) return 0 ;; esac
  return 1
}
for signal in TERM KILL; do
  ps -axo pid=,command= | while read -r pid command; do
    if ours "$command"; then kill -s "$signal" "$pid" 2> /dev/null; fi
  done
  sleep 2
done
[ -n "$check" ] && rm -rf "$check"
if [ -f "$job/worlds" ]; then
  while read -r world; do
    [ -n "$world" ] || continue
    rm -rf "$HOME/Library/Application Support/Copper ($world)"
    defaults delete "com.collinrijock.copper.test.$world" 2> /dev/null
    rm -f "$HOME/Library/Preferences/com.collinrijock.copper.test.$world.plist"
  done < "$job/worlds"
fi
if [ -f "$job/made" ]; then
  while read -r made; do
    [ -n "$made" ] && rm -rf "$made"
  done < "$job/made"
fi
rm -rf "$job"
rmdir "$(dirname "$job")" 2> /dev/null
exit 0
REMOTE
    if mini 30 "test ! -e '$job'"; then
      echo "    removed $MINI:$job"
    else
      echo "release-local: could not remove $MINI:$job — delete it by hand" >&2
    fi
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# rcodesign, fetched once into a cache and checked against the pins on every
# run: the tarball against the published SHA-256 and the pinned one, the
# binary against its own.
rcodesign="${XDG_CACHE_HOME:-$HOME/.cache}/copper-release/apple-codesign-$RCODESIGN_VERSION/rcodesign"
if [ ! -x "$rcodesign" ] || [ "$(shasum -a 256 "$rcodesign" | cut -d' ' -f1)" != "$RCODESIGN_SHA256" ]; then
  note "fetching rcodesign $RCODESIGN_VERSION"
  curl -fsSL --retry 3 -o "$work/$RCODESIGN_TARBALL" "$RCODESIGN_URL"
  published="$(curl -fsSL --retry 3 "$RCODESIGN_URL.sha256" | tr -d '[:space:]')"
  actual="$(shasum -a 256 "$work/$RCODESIGN_TARBALL" | cut -d' ' -f1)"
  [ "$published" = "$RCODESIGN_TARBALL_SHA256" ] || fail "rcodesign's published SHA-256 is $published, pinned $RCODESIGN_TARBALL_SHA256"
  [ "$actual" = "$RCODESIGN_TARBALL_SHA256" ] || fail "$RCODESIGN_TARBALL is $actual, pinned $RCODESIGN_TARBALL_SHA256"
  tar -xzf "$work/$RCODESIGN_TARBALL" -C "$work"
  binary="$work/${RCODESIGN_TARBALL%.tar.gz}/rcodesign"
  [ "$(shasum -a 256 "$binary" | cut -d' ' -f1)" = "$RCODESIGN_SHA256" ] || fail "the rcodesign in $RCODESIGN_TARBALL is not the pinned binary"
  mkdir -p "$(dirname "$rcodesign")"
  install -m 755 "$binary" "$rcodesign"
fi
note "signer   $("$rcodesign" --version) ($rcodesign)"

# ---------------------------------------------------------------------------
step "Build on the Mac mini ($MINI)"

remote_dir="$REMOTE_DIR"
# A literal ~/ (quoted, so this shell leaves it be) is the mini's home.
# shellcheck disable=SC2088,SC2016  # both are for the mini's shell, not this one
case "$remote_dir" in "~/"*) remote_dir="$(mini 30 'printf %s "$HOME"')/${remote_dir#"~/"}" ;; esac
case "$remote_dir" in
  /*) ;;
  *) fail "COPPER_RELEASE_REMOTE_DIR must be absolute or start with ~/, got: $REMOTE_DIR" ;;
esac
# It goes into ssh command lines in single quotes.
case "$remote_dir" in
  *[!A-Za-z0-9._/-]*) fail "COPPER_RELEASE_REMOTE_DIR may hold letters, digits, . _ - and / only, got: $remote_dir" ;;
esac
# The disk it is on, or will be: the nearest folder of it that exists.
free_kb="$(mini 60 "d='$remote_dir'; while [ ! -d \"\$d\" ]; do d=\"\$(dirname \"\$d\")\"; done; df -k \"\$d\" | awk 'NR == 2 { print \$4 }'")"
free_gb="$(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"
note "$free_gb GB free for $remote_dir"
[ "$free_kb" -ge $((REMOTE_FREE_GB * 1024 * 1024)) ] \
  || fail "the mini has $free_gb GB free for $remote_dir; a release build wants $REMOTE_FREE_GB (COPPER_RELEASE_REMOTE_DIR='~/farm/copper-release' builds on its internal disk)"
if $preflight; then
  step "Preflight only: everything checks out for $tag; nothing was built"
  exit 0
fi

# Only now: a run that stopped in preflight leaves the last one's output be.
rm -rf "$out"
mkdir -p "$assets" "$logs"
job="$remote_dir/$version-$(date -u +%H%M%S)-$$"
on_mini=true
mini 60 mkdir -p "$job/src"
note "job      $job"
# Exactly the commit's tree: nothing uncommitted, nothing ignored.
git archive --format=tar "$commit" | mini 600 tar -x -C "$job/src"

mini 60 "cat > '$job/build.sh'" <<'REMOTE'
#!/bin/bash
# The workflow's three build steps, on the mini, with its assertions.
set -euo pipefail
job="$1"
cd "$job/src"
fail() { echo "error: $*" >&2; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# With SEARCH_SIGN_IDENTITY empty, build.sh asks the keychain for a Developer
# ID. A release never wants one (it is signed again on the laptop), and this
# path touches no keychain on either Mac, so build.sh gets a `security` that
# finds nothing: its ad-hoc signature, as on the runner.
mkdir -p "$job/no-keychain"
printf '#!/bin/sh\nexit 0\n' > "$job/no-keychain/security"
chmod 755 "$job/no-keychain/security"
export PATH="$job/no-keychain:$PATH"

echo "--- toolchain"
xcodebuild -version
swift --version

echo "--- COPPER_RELEASE=1 ./build.sh release app"
COPPER_RELEASE=1 SEARCH_SIGN_IDENTITY= ./build.sh release app
test -d build/Copper.app/Contents/MacOS || fail "no build/Copper.app"
test "$(plutil -extract CFBundleIdentifier raw -o - build/Copper.app/Contents/Info.plist)" = com.collinrijock.copper \
  || fail "build/Copper.app is not com.collinrijock.copper"
test "$(lipo -archs build/Copper.app/Contents/MacOS/Copper)" = arm64 || fail "build/Copper.app is not arm64"

echo "--- swift test --filter xosInsert"
# Some Xcodes keep swift-testing's macros where SwiftPM doesn't look; then
# the test target can't expand @Test, and the plugin is named explicitly.
if ! swift test --filter xosInsert 2>&1 | tee "$job/swift-test.log"; then
  plugin="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
  grep -q TestingMacros "$job/swift-test.log" && [ -f "$plugin" ] || fail "swift test --filter xosInsert failed"
  echo "--- swift test --filter xosInsert (with $plugin)"
  swift test --filter xosInsert -Xswiftc -load-plugin-library -Xswiftc "$plugin"
fi

echo "--- COPPER_RELEASE=1 COPPER_ARCH=x86_64 ./build.sh release app"
COPPER_RELEASE=1 COPPER_ARCH=x86_64 SEARCH_SIGN_IDENTITY= ./build.sh release app
test "$(lipo -archs build/x86_64/Copper.app/Contents/MacOS/Copper)" = x86_64 || fail "build/x86_64/Copper.app is not x86_64"
# The resources the arm64 app carries (backdrop, canvas, addons bridge).
diff <(ls build/Copper.app/Contents/Resources) <(ls build/x86_64/Copper.app/Contents/Resources) \
  || fail "the two apps carry different resources"
test -d build/x86_64/Copper.app/Contents/Resources/Search_Search.bundle || fail "no Search_Search.bundle in the Intel app"
test "$(plutil -extract CFBundleIdentifier raw -o - build/x86_64/Copper.app/Contents/Info.plist)" = com.collinrijock.copper \
  || fail "build/x86_64/Copper.app is not com.collinrijock.copper"
echo "--- built"
REMOTE

# The build streams here and into logs/; the mini is shared, so one build at a time.
mini 5400 bash "$job/build.sh" "$job" < /dev/null 2>&1 | tee "$logs/mini-build.log"

step "Bring the unsigned apps and dSYMs back"
mkdir -p "$work/build"
# Only the bundles; COPYFILE_DISABLE keeps the mini's tar from adding ._ files.
mini 900 "cd '$job/src/build' && COPYFILE_DISABLE=1 tar -cf - \$(ls -d Copper.app Copper.app.dSYM x86_64/Copper.app x86_64/Copper.app.dSYM 2> /dev/null)" \
  | tar -x -C "$work/build"
# What the build took on the mini, for REMOTE_FREE_GB above.
note "the build used $(mini 120 "du -sk '$job' | awk '{ printf \"%.1f\", \$1 / 1048576 }'") GB on the mini"
# The sources and the build products are gigabytes on a shared disk; only the
# launch check still needs the mini, and it brings its own files.
mini 300 rm -rf "$job/src"
for app in "$work/build/Copper.app" "$work/build/x86_64/Copper.app"; do
  [ -x "$app/Contents/MacOS/Copper" ] || fail "missing $app"
done

# ---------------------------------------------------------------------------
step "Stamp $version, sign with rcodesign, zip"

git show "$commit:release/designated-requirement.txt" > "$work/requirement.txt"
# rcodesign takes the requirement compiled, not as text; csreq compiles it the
# way codesign -r would.
csreq -r "$work/requirement.txt" -b "$work/requirement.bin"
[ "$(csreq -r "$work/requirement.bin" -t)" = "$requirement" ] || fail "csreq did not round-trip the requirement"

# release/package-app.sh's stamp and checks, with rcodesign doing what
# codesign and a keychain do there.
sign_and_zip() {
  local app="$1" arch="$2"
  local plist="$app/Contents/Info.plist"
  [ "$(lipo -archs "$app/Contents/MacOS/Copper")" = "$arch" ] || fail "$app is not built for $arch"
  local bundle_id
  bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  case "$requirement" in
    *"identifier \"$bundle_id\" "*) ;;
    *) fail "bundle id $bundle_id is not the release's ($requirement)" ;;
  esac
  # The updater inside checks every later release against the same
  # certificate (Fork/Signing.swift); a bundle that pins another isn't signed.
  LC_ALL=C grep -a -q -F "$want" "$app/Contents/MacOS/Copper" \
    || fail "the $arch app's updater does not pin $want (Fork/Signing.swift)"

  # Homebrew needs a monotonic version; About and MCP serverInfo show it.
  plutil -replace CFBundleShortVersionString -string "$version" "$plist"

  # rcodesign carries an existing signature's flags and entitlements over, so
  # build.sh's ad-hoc one goes first: the release signature has only what is
  # given below — no hardened runtime, no entitlements, no timestamp, like
  # package-app.sh's.
  codesign --remove-signature "$app"
  rm -rf "$app/Contents/_CodeSignature"
  # One pass, inside out: nested code first, then the app with the explicit
  # requirement (rcodesign applies --code-requirements-file to the main
  # entity only, as package-app.sh's second codesign does). Contents/Resources
  # is data, as codesign's own rules have it: the SwiftPM resource bundle there
  # is sealed file by file, not signed as a bundle of its own.
  "$rcodesign" sign \
    --p12-file "$P12" --p12-password-file "$P12_PASSWORD" \
    --code-requirements-file "$work/requirement.bin" \
    --timestamp-url none \
    --exclude 'Contents/Resources/**' \
    "$app" > "$logs/rcodesign-$arch.log" 2>&1 \
    || { tail -20 "$logs/rcodesign-$arch.log" >&2; fail "rcodesign could not sign the $arch app"; }
  if ! codesign --verify --deep --strict -R="$requirement" "$app"; then
    codesign -d --extract-certificates="$work/cert-$arch-" "$app" 2> /dev/null
    fail "the $arch app does not satisfy $requirement (signed with $(shasum -a 1 "$work/cert-$arch-0" 2> /dev/null | cut -d' ' -f1))"
  fi
  note "$arch: $(codesign -d -r- "$app" 2> /dev/null | grep '^designated')"

  # This Mac gives every file a com.apple.provenance attribute, and ditto
  # would carry it into the zip as ._ AppleDouble files — which a plain unzip
  # leaves in the bundle, unsealed. The runner's zips have none, nor do these.
  local zip="copper-${version}-macos-${arch}.zip"
  ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app" "$assets/$zip"
  (cd "$assets" && shasum -a 256 "$zip" > "$zip.sha256")
  note "$arch: stamped $(plutil -extract CFBundleShortVersionString raw -o - "$plist") (build $(plutil -extract CFBundleVersion raw -o - "$plist")), packed $zip ($(du -h "$assets/$zip" | cut -f1 | tr -d " "))"
}

sign_and_zip "$work/build/Copper.app" arm64
sign_and_zip "$work/build/x86_64/Copper.app" x86_64
if [ -x "$work/build/Copper.app/Contents/Resources/bin/copper" ]; then has_cli=true; else has_cli=false; fi
sha256="$(cut -d' ' -f1 < "$assets/$zip_name.sha256")"
x86_64_sha256="$(cut -d' ' -f1 < "$assets/$x86_64_zip_name.sha256")"
# Stable names for releases/latest/download/… (installer, site).
cp "$assets/$zip_name" "$assets/copper-macos-arm64.zip"
printf '%s  copper-macos-arm64.zip\n' "$sha256" > "$assets/copper-macos-arm64.zip.sha256"
cp "$assets/$x86_64_zip_name" "$assets/copper-macos-x86_64.zip"
printf '%s  copper-macos-x86_64.zip\n' "$x86_64_sha256" > "$assets/copper-macos-x86_64.zip.sha256"
git show "$commit:release/copper-install.sh" > "$assets/copper-install.sh"

# ---------------------------------------------------------------------------
step "Check the signature (the shipped zips)"

for arch in arm64 x86_64; do
  echo "--- $arch"
  check="$work/check-$arch"
  rm -rf "$check" && mkdir -p "$check"
  ditto -x -k "$assets/copper-${version}-macos-${arch}.zip" "$check"
  app="$check/Copper.app"
  # What the updater reads before it stages an update (Fork/Updates.swift
  # fetchAndStage): the bundle id, the version, the CPU.
  [ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = com.collinrijock.copper ] || fail "$arch: not com.collinrijock.copper"
  [ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = "$version" ] || fail "$arch: not stamped $version"
  [ "$(lipo -archs "$app/Contents/MacOS/Copper")" = "$arch" ] || fail "$arch: the binary is $(lipo -archs "$app/Contents/MacOS/Copper")"
  # The designated requirement macOS files grants under: the same text for
  # every release, and for both CPUs.
  dr="$(codesign -d -r- "$app" 2> /dev/null | sed -n 's/^designated => //p')"
  echo "designated => $dr"
  [ "$dr" = "$requirement" ] || fail "$arch: designated requirement is '$dr', expected '$requirement'"
  # The updater's own two checks, argument for argument (Updates.swift, then
  # Signing.unsatisfied): integrity alone, which is all a Copper from before
  # signing checks, and the requirement.
  codesign --verify --deep --strict "$app" || fail "$arch: codesign --verify --deep --strict failed"
  codesign --verify --deep --strict -R "=$requirement" "$app" || fail "$arch: does not satisfy $requirement"
  details="$(codesign -dvv "$app" 2>&1)"
  printf '%s\n' "$details" | grep -E '^(Identifier|Format|CodeDirectory|Authority|Signature|TeamIdentifier|Runtime|Sealed)' || true
  # No hardened runtime and no other flags, as every release so far.
  printf '%s\n' "$details" | grep -q '^CodeDirectory .* flags=0x0(none) ' || fail "$arch: code signature flags are set; releases carry none"
  printf '%s\n' "$details" | grep -q '^Authority=Copper Release Signing$' || fail "$arch: not signed by Copper Release Signing"
  entitlements="$(codesign -d --entitlements - "$app" 2> /dev/null || true)"
  [ -z "$entitlements" ] || { printf '%s\n' "$entitlements"; fail "$arch: entitlements appeared; releases carry none"; }
  echo "cdhash $(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
done

# ---------------------------------------------------------------------------
step "Zip the dSYMs"

# The release binary ships stripped; this is what names its crash reports.
# Only attached when its UUID is the shipped binary's (signing keeps LC_UUID) —
# a dSYM that doesn't match would only mislead. Missing is a warning, as in
# build.sh and the workflow.
for arch in arm64 x86_64; do
  app="$work/build/Copper.app"
  [ "$arch" = arm64 ] || app="$work/build/$arch/Copper.app"
  dsym="$app.dSYM"
  if [ ! -d "$dsym" ]; then
    note "warning: no $arch dSYM — this release's $arch crash reports won't symbolicate"
    continue
  fi
  app_uuid="$(dwarfdump --uuid "$app/Contents/MacOS/Copper" | awk '{print $2}')"
  dsym_uuid="$(dwarfdump --uuid "$dsym" | awk '{print $2}')"
  note "$arch: binary $app_uuid · dSYM $dsym_uuid"
  if [ -z "$app_uuid" ] || [ "$app_uuid" != "$dsym_uuid" ]; then
    note "warning: $arch dSYM UUID $dsym_uuid is not the binary's $app_uuid; not attaching it"
    continue
  fi
  ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$dsym" "$assets/copper-${version}-macos-${arch}.dSYM.zip"
done

# ---------------------------------------------------------------------------
step "Write copper-version.json"

# The workflow's manifest, verbatim: the same schema, fields and order, and
# the same first paragraph of NOTES.md (at this commit) as what is new.
mkdir -p "$work/meta"
git show "$commit:NOTES.md" > "$work/meta/NOTES.md" 2> /dev/null || : > "$work/meta/NOTES.md"
# shellcheck disable=SC2016  # JavaScript, not shell
(
  cd "$work/meta"
  OUT="$assets" VERSION="$version" TAG="$tag" COMMIT="$commit" SHA256="$sha256" ZIP_NAME="$zip_name" \
    X86_64_SHA256="$x86_64_sha256" X86_64_ZIP_NAME="$x86_64_zip_name" HAS_CLI="$has_cli" \
    PUBLISHED_AT="$published_at" GITHUB_REPOSITORY="$REPO" \
    node -e '
      const fs = require("fs");
      const e = process.env;
      const base = `https://github.com/${e.GITHUB_REPOSITORY}/releases`;
      // What is new: the first paragraph of NOTES.md, the gist the
      // CHANGELOG hands it when a version ships. The sidebar update pill
      // shows it under What is New (Fork/UpdatePill.swift). Optional.
      // (No apostrophes in here: this is a single-quoted shell string.)
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
        source: `https://github.com/${e.GITHUB_REPOSITORY}/commit/${e.COMMIT}`,
        status: "lkg",
        publishedAt: e.PUBLISHED_AT,
        arch: "arm64",
        zip: e.ZIP_NAME,
        sha256: e.SHA256,
        hasCli: e.HAS_CLI === "true",
        archiveUrl: `${base}/download/${e.TAG}/${e.ZIP_NAME}`,
        latestUrl: `${base}/latest/download/copper-macos-arm64.zip`,
        // One per CPU. The fields above stay those of the arm64 archive:
        // every Copper from before the Intel build reads only them
        // (Fork/Updates.swift).
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
)
cat "$assets/copper-version.json"
# If release.yml's manifest gains or loses a field, the two paths would hand
# the updater and the tap different shapes: hold this one to the published one.
curl -fsSL --retry 3 -o "$work/published-version.json" "https://github.com/$REPO/releases/latest/download/copper-version.json"
# shellcheck disable=SC2016  # JavaScript, not shell
node -e '
  const fs = require("fs");
  const paths = (o, p = "") => Object.entries(o).flatMap(([k, v]) =>
    v && typeof v === "object" && !Array.isArray(v) ? paths(v, p + k + ".") : [p + k + ":" + typeof v]);
  const mine = paths(JSON.parse(fs.readFileSync(process.argv[1], "utf8"))).join("\n");
  const theirs = paths(JSON.parse(fs.readFileSync(process.argv[2], "utf8"))).join("\n");
  if (mine !== theirs) { console.error("this manifest:\n" + mine + "\n\nthe published one:\n" + theirs); process.exit(1); }
' "$assets/copper-version.json" "$work/published-version.json" \
  || fail "copper-version.json does not have the published manifest's fields (release.yml changed? keep the two in step)"
note "copper-version.json has the published manifest's fields, in its order"
(cd "$assets" && shasum -a 256 ./*)

# ---------------------------------------------------------------------------
step "Launch the shipped apps on the mini (headless, throwaway worlds)"

mini 60 mkdir -p "$job/launch"
COPYFILE_DISABLE=1 tar -C "$assets" -cf - "$zip_name" "$x86_64_zip_name" | mini 600 tar -x -C "$job/launch"
mini 60 "cat > '$job/launch.sh'" <<'REMOTE'
#!/bin/bash
# A signed release must start like any other: open the unzipped bundle
# headless in a world of its own and ask it its version.
set -euo pipefail
job="$1" version="$2"
fail() { echo "error: $*" >&2; exit 1; }
# Nobody is at this Mac, but someone is logged in, and an app has to start in
# that session: `open` from ssh has no window server (LaunchServices answers
# -10810) and `launchctl asuser` needs root. A one-shot agent in the session's
# own launchd domain runs `open` there instead. What runs in that session may
# not read the external disk (macOS keeps removable volumes from it), so the
# two unzipped apps go in this user's temporary folder on the internal one,
# and are deleted with the job.
check="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)copper-release-check.XXXXXX")"
echo "$check" > "$job/check-dir"
gui="gui/$(id -u)"
# As Copper itself, the apps also make WebKit's and the URL cache's folders
# for com.collinrijock.copper. Those this check brings into being go with it;
# any that were here before are someone else's.
for made in "$HOME/Library/WebKit/com.collinrijock.copper" "$HOME/Library/Caches/com.collinrijock.copper" \
  "$HOME/Library/HTTPStorages/com.collinrijock.copper" "$HOME/Library/HTTPStorages/com.collinrijock.copper.binarycookies" \
  "$HOME/Library/Saved Application State/com.collinrijock.copper.savedState"; do
  [ -e "$made" ] || echo "$made" >> "$job/made"
done
launch() {
  local arch="$1" seconds="$2"
  local dir="$check/$arch"
  mkdir -p "$dir"
  ditto -x -k "$job/launch/copper-$version-macos-$arch.zip" "$dir"
  local app="$dir/Copper.app"
  # A world and a port no one else has; the cleanup forgets the world again.
  # Letters, digits and dashes only: Copper drops anything else from a world's
  # name (x86_64 would be the world x8664).
  local world
  world="release-local-${arch//_/-}-$(date +%s)-$$"
  echo "$world" >> "$job/worlds"
  local port
  while :; do
    port=$((41000 + RANDOM % 8000))
    lsof -nP -iTCP:"$port" -sTCP:LISTEN > /dev/null 2>&1 || break
  done
  defaults write "com.collinrijock.copper.test.$world" welcomed -bool true
  local label="com.exowatt.copper-release-check.$world"
  echo "$label" >> "$job/labels"
  cat > "$check/$arch.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string><string>-n</string><string>-g</string>
    <string>--stderr</string><string>$check/launch-$arch.log</string>
    <string>--env</string><string>SEARCH_PROBE=$world</string>
    <string>--env</string><string>SEARCH_HEADLESS=1</string>
    <string>--env</string><string>SEARCH_MCP_PORT=$port</string>
    <string>$app</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$check/agent-$arch.log</string>
  <key>StandardErrorPath</key><string>$check/agent-$arch.log</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "$gui" "$check/$arch.plist"
  local health="" pid=""
  for _ in $(seq 1 "$seconds"); do
    health="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2> /dev/null || true)"
    [ -n "$health" ] && break
    sleep 1
  done
  # The agent only ran `open`; the app is LaunchServices' now.
  launchctl bootout "$gui/$label" 2> /dev/null || true
  pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2> /dev/null | head -1 || true)"
  # Only our own: the process listening on our port, running our bundle.
  if [ -n "$pid" ]; then
    case "$(ps -o command= -p "$pid")" in
      "$app"/* | "/private$app"/*)
        kill "$pid"
        for _ in $(seq 1 15); do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
        kill -9 "$pid" 2> /dev/null || true
        ;;
      *) echo "port $port is held by pid $pid, not this check's app; leaving it" >&2 ;;
    esac
  fi
  if [ -z "$health" ]; then
    cat "$check/agent-$arch.log" "$check/launch-$arch.log" >&2 || true
    fail "the signed $arch app did not answer /health on $port within $seconds s"
  fi
  echo "$arch: $health"
  case "$health" in
    *"$version"*) ;;
    *) fail "$arch: /health does not report $version" ;;
  esac
}
launch arm64 90
# The Intel bundle the same way, translated by Rosetta. A Mac without Rosetta
# still checked its signature and CPU.
if /usr/bin/arch -x86_64 /usr/bin/true 2> /dev/null; then
  launch x86_64 120
else
  echo "warning: Rosetta is not installed on this Mac, so the Intel app was checked but not launched" >&2
fi
REMOTE
mini 600 bash "$job/launch.sh" "$job" "$version" < /dev/null 2>&1 | tee "$logs/mini-launch.log"

# The release text, as the workflow writes it.
cat > "$out/release-notes.md" <<EOF
Copper ${version} — built from ${REPO}@${commit:0:12}.

**Install**

\`\`\`sh
brew install --cask copper-browser/copper/copper
\`\`\`

or

\`\`\`sh
curl -fsSL https://github.com/${REPO}/releases/latest/download/copper-install.sh | sh
\`\`\`

or download the zip for your Mac below — \`${zip_name}\` for Apple Silicon, \`${x86_64_zip_name}\` for Intel — unzip, move Copper.app to /Applications and run \`xattr -cr /Applications/Copper.app\` once (signed with Copper's own certificate, not notarized).

macOS 14 Sonoma or later, Apple Silicon or Intel. Already installed? Copper updates itself — Settings › Updates.

sha256 \`${sha256}\` (arm64)
sha256 \`${x86_64_sha256}\` (x86_64)
EOF

# ---------------------------------------------------------------------------
if $dry_run; then
  step "Dry run: nothing published"
  note "no tag, no release, no upload — what would ship is in $assets"
else
  step "Publish $tag"
  # The build took a while; a workflow run may have taken this number since.
  if gh release view "$tag" -R "$REPO" > /dev/null 2>&1 \
    || gh api "repos/$REPO/git/ref/tags/$tag" > /dev/null 2>&1; then
    fail "$tag appeared in $REPO during the build; nothing uploaded — run again for the next number"
  fi
  dsym_zips=()
  for arch in arm64 x86_64; do
    [ -f "$assets/copper-${version}-macos-${arch}.dSYM.zip" ] && dsym_zips+=("$assets/copper-${version}-macos-${arch}.dSYM.zip")
  done
  gh release create "$tag" \
    --repo "$REPO" \
    --target "$commit" \
    --title "Copper ${version}" \
    --notes-file "$out/release-notes.md" \
    --latest \
    "$assets/$zip_name" "$assets/$zip_name.sha256" \
    "$assets/copper-macos-arm64.zip" "$assets/copper-macos-arm64.zip.sha256" \
    "$assets/$x86_64_zip_name" "$assets/$x86_64_zip_name.sha256" \
    "$assets/copper-macos-x86_64.zip" "$assets/copper-macos-x86_64.zip.sha256" \
    "$assets/copper-version.json" "$assets/copper-install.sh" \
    ${dsym_zips[@]+"${dsym_zips[@]}"}

  step "Verify the published bytes"
  # What the updater, the installer and the cask download — the versioned
  # zips, and the stable names and manifest behind releases/latest — are these
  # bytes. latest/ can take a moment to point at the new release.
  verify() {
    local url="$1" want="$2" actual=""
    for _ in 1 2 3 4 5 6; do
      actual="$(curl -fsSL --retry 5 --retry-delay 3 "$url" | shasum -a 256 | cut -d' ' -f1)"
      [ "$actual" = "$want" ] && { note "OK $url"; return 0; }
      sleep 5
    done
    fail "$url serves $actual, expected $want"
  }
  verify "https://github.com/$REPO/releases/download/$tag/$zip_name" "$sha256"
  verify "https://github.com/$REPO/releases/download/$tag/$x86_64_zip_name" "$x86_64_sha256"
  verify "https://github.com/$REPO/releases/latest/download/copper-macos-arm64.zip" "$sha256"
  verify "https://github.com/$REPO/releases/latest/download/copper-macos-x86_64.zip" "$x86_64_sha256"
  verify "https://github.com/$REPO/releases/latest/download/copper-version.json" \
    "$(shasum -a 256 "$assets/copper-version.json" | cut -d' ' -f1)"
fi

step "Copper $version"
if $dry_run; then
  note "dry run: nothing published (no tag, no release); the signed zips are in $assets"
else
  note "release: https://github.com/$REPO/releases/tag/$tag"
  note "the tap (copper-browser/homebrew-copper) picks this up from copper-version.json on its next bump run"
fi
note "source: https://github.com/$REPO/commit/$commit"
note "sha256 (arm64): $sha256"
note "sha256 (x86_64): $x86_64_sha256"
note "signed: $requirement ($("$rcodesign" --version))"
note "CLI shim in bundle: $has_cli"
