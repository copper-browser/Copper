#!/bin/bash
# Cut a Copper release on a Mac: build, sign with Exowatt's Developer ID,
# notarize, check, launch, publish. Roadrunner runs it on its macOS agent
# (.woodpecker/release.yaml through release/release-ci.sh, with --here); by
# hand it builds on the Mac mini and signs where it runs (docs/releasing.md).
#
#   release/release-local.sh --dry-run          build and sign; no notarization, no tag, no release
#   release/release-local.sh --dry-run --notarize
#                                               and notarize, staple and check that too
#   release/release-local.sh                    publish fork's HEAD as the next version
#   release/release-local.sh --version 1.0.20261111.106 [--dry-run]
#   release/release-local.sh --preflight        only the checks before the build
#   release/release-local.sh --here …           everything on this Mac (the build, the
#                                               launch check); no ssh. Roadrunner's way
#   release/release-local.sh --fresh …          start over: forget what a stopped run left
#   release/release-local.sh --again …          release a commit that already has a release
#   release/release-local.sh --reuse-assets <commit>
#                                               check, launch and publish the assets a
#                                               run left in <out>/<version>
#                                               (built from <commit>) without rebuilding
#
#   COPPER_RELEASE_BUILD_HERE=~/src/sign-builds/copper release/release-local.sh …
#                                               build on this Mac, in that folder
#                                               (default: on the mini, in REMOTE_DIR)
#   COPPER_RELEASE_REMOTE_DIR='~/sign-builds/copper' release/release-local.sh …
#                                               the folder on the mini (with --here, on
#                                               this Mac) for the build and the launch check
#   COPPER_RELEASE_OUT=<folder>                 where runs keep their state and assets
#                                               (<out>; default build/release-local)
#
# A publishing run that stops — Apple still notarizing at the deadline (exit
# 75), a lost connection, a killed pipeline — keeps what it made in
# <out>/<version>/: the built apps, each signed zip and disk image, and the id
# of every notary submission (release/package-app.sh, release/notary.sh). Run
# it again on the same commit and it takes the same version and carries on:
# it doesn't build or sign again what it has, never sends Apple bytes it
# already sent (it waits on that submission), and publishes what is notarized.
# A commit that already has a release is not released again (--again does).
#
# Every release is the same whoever cuts it — the same build commands and
# checks, the same signature (release/package-app.sh: Exowatt's Developer ID,
# the hardened runtime, the provisioning profile, the entitlements it allows
# and the requirement in release/designated-requirement.txt), notarized and
# stapled, the same assets, the same copper-version.json and the same release
# text — so the updater, the curl installer and the Homebrew tap can't tell
# where a release was cut.
#
# Where each part runs, and why:
#   - This Mac: preflight, version, signing, notarizing, packaging,
#     publishing. The Developer ID key and the App Store Connect key
#     (exo-macsign's: EXO_MACSIGN_* or ~/.config/exowatt-apple-signing, 0600)
#     never leave it, and no keychain is involved anywhere: rcodesign reads the
#     .p12 itself, notarytool the .p8. EXO_MACSIGN_* from the environment go
#     into 0600 files in a private folder that is deleted when the run ends,
#     and are unset, so nothing the run starts (the build) sees them.
#   - The builds and the Xos test: here when COPPER_RELEASE_BUILD_HERE names a
#     folder, otherwise on the Mac mini (MINI below). One heavy job at a time
#     on either: the build waits for COPPER_RELEASE_LOCK (lockf), at nice 10.
#   - The launch check: on the mini, in a session nobody is using, with
#     Rosetta for the Intel build (--here: on this Mac, when this account has
#     a login session; a Roadrunner agent has none, so it is skipped there). Only the two zips go there; the job
#     folder (REMOTE_DIR below) is deleted at the end, whatever happened.
#
# The version is <VERSION file>.<UTC YYYYMMDD>.<n>, n one more than the highest
# trailing number of any v… tag or release in copper-browser/Copper, so it
# never takes a number a release already has or sorts below one.
#
# Writes <out>/<version>/ (dry runs: <out>/dry-run/<version>/): assets/ is
# exactly what a release uploads, release-notes.md its text, logs/ the build
# and sign logs, build/ the apps while a release is under way, state/ the
# notary submissions. <out>/commits/<commit> names the version a commit's
# release has taken.
set -euo pipefail

REPO=copper-browser/Copper
MINI=felipe-exowatt@100.112.175.26
# Where the job folder goes on the mini: its internal disk (quoted, so ~ is
# the mini's). The external one, /Volumes/Farm, can hang a shell that only
# lists it while macOS waits on a removable-volume prompt nobody sees.
REMOTE_DIR="${COPPER_RELEASE_REMOTE_DIR:-~/sign-builds/copper}"
# Build here instead, in this folder (absolute, or ~/…).
BUILD_HERE="${COPPER_RELEASE_BUILD_HERE:-}"
# The lock every heavy build on a Mac shares with the other app releases cut
# there, so two compiles never fight for its cores and memory.
LOCK="${COPPER_RELEASE_LOCK:-/tmp/exo-sign-build.lock}"
# Free space the build wants. It compiles three configurations (arm64
# release, the debug build swift test needs, x86_64 release), each about 1 GB
# of .build, plus the sources and the two apps with their dSYMs: about 3.5 GB.
# The build reports what it used, and stops if the disk drops below
# BUILD_FLOOR_GB while it runs (the mini's disk is shared and nearly full).
# The launch check alone wants the zips.
BUILD_FREE_GB=6
BUILD_FLOOR_GB=3
LAUNCH_FREE_GB=1
# The signing credentials: exo-macsign's (docs/releasing.md › Credentials).
SIGNING="${EXO_MACSIGN_CONFIG_DIR:-$HOME/.config/exowatt-apple-signing}"
BUNDLE_ID=com.collinrijock.copper

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
step() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'release-local: %s\n' "$*" >&2; exit 1; }

args=("$@")
dry_run=false
preflight=false
notarize=true
notarize_dry=false
here=false
fresh=false
again=false
version=""
reuse=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --preflight) preflight=true; dry_run=true ;;
    --notarize) notarize_dry=true ;;
    --here) here=true ;;
    --fresh) fresh=true ;;
    --again) again=true ;;
    --version) version="${2:?--version needs a value}"; shift ;;
    --version=*) version="${1#*=}" ;;
    --reuse-assets) reuse="${2:?--reuse-assets needs the commit they were built from}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# A dry run sends nothing to Apple unless --notarize asks it to; a release
# always notarizes.
! $dry_run || $notarize_dry || notarize=false

cd "$(dirname "$0")/.."
root="$(pwd)"
# Where runs keep what they make: per version, and per commit the version its
# release took (absolute: the build and launch steps cd elsewhere).
OUT_ROOT="${COPPER_RELEASE_OUT:-$root/build/release-local}"
case "$OUT_ROOT" in /*) ;; *) fail "COPPER_RELEASE_OUT must be absolute, got: $OUT_ROOT" ;; esac
# One run at a time per <out>: two would share a version's state.
if [ -z "${COPPER_RELEASE_LOCKED:-}" ] && ! $preflight; then
  mkdir -p "$OUT_ROOT"
  # (Asked first: lockf's own "busy" is exit 75, which is also "Apple is still notarizing".)
  /usr/bin/lockf -s -t 0 "$OUT_ROOT/.lock" true || fail "another release run is using $OUT_ROOT"
  COPPER_RELEASE_LOCKED=1 exec /usr/bin/lockf -t 0 "$OUT_ROOT/.lock" "$root/release/release-local.sh" ${args[@]+"${args[@]}"}
fi
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
# Every call to the mini has a deadline, so a dropped connection is an error
# and not a terminal waiting forever. With --here, "the mini" is this Mac:
# the same commands run in a local shell.
mini() {
  local seconds="$1"
  shift
  if $here; then bash -c "$*"; else timeout "$seconds" ssh "${ssh_opts[@]}" "$MINI" "$@"; fi
}
where="$MINI"
! $here || where="this Mac"

# ---------------------------------------------------------------------------
step "Preflight"

tools=(git gh node curl shasum ditto codesign csreq plutil lipo dwarfdump tar xcrun spctl python3 hdiutil openssl)
$here || tools+=(timeout ssh)
for tool in "${tools[@]}"; do
  command -v "$tool" > /dev/null || fail "needs $tool on PATH"
done
gh auth status > /dev/null 2>&1 || fail "gh is not signed in (gh auth login, or GH_TOKEN)"

commit="$(git rev-parse HEAD)"
fork_head="$(gh api "repos/$REPO/branches/fork" --jq .commit.sha)"
dirty="$(git status --porcelain)"
note "commit   $commit"
note "fork     $fork_head ($REPO)"
# A release is a commit of fork, built from a tree that is exactly that
# commit: fork's HEAD, or one fork has moved past since (a pipeline started on
# it, a tag, a run carried on hours later). The build itself is
# `git archive <commit>`, so a dry run of a dirty tree still builds only what
# is committed; it says so.
if [ "$commit" != "$fork_head" ]; then
  on_fork="$(gh api "repos/$REPO/compare/$commit...$fork_head" --jq .status 2> /dev/null || true)"
  if [ "$on_fork" = ahead ]; then
    note "fork has moved on since $commit; releasing $commit"
  else
    $dry_run || fail "HEAD is not a commit of $REPO fork ($fork_head is its head); a release is built from fork only"
    note "dry run of a commit that is not on fork"
  fi
fi
if [ -n "$dirty" ]; then
  $dry_run || fail "the working tree has uncommitted changes; a release is built from a clean tree"
  note "dry run: uncommitted changes are not in the build (it is $(git rev-parse --short=12 HEAD) as committed)"
fi
# --reuse-assets: the signed, notarized assets of a run that stopped after
# packaging (build/release-local/<version>/), checked and published as they
# are instead of built and notarized again (two to four hours of Apple's
# queue on a slow day). The release is the commit they were built from, and
# that commit's tree must be HEAD's but for this script and docs/.
if [ -n "$reuse" ]; then
  reuse="$(git rev-parse --verify --quiet "$reuse^{commit}")" || fail "--reuse-assets: no such commit"
  git merge-base --is-ancestor "$reuse" "$commit" || fail "--reuse-assets: $reuse is not an ancestor of HEAD"
  changed="$(git diff --name-only "$reuse" "$commit" -- . ':(exclude)release/release-local.sh' ':(exclude)docs')"
  [ -z "$changed" ] || fail "--reuse-assets: $reuse differs from HEAD in what a release is made of: $changed"
  commit="$reuse"
  note "reuse    the assets built from $commit"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/copper-release.XXXXXX")"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

# The keys and the password, exo-macsign's: from the environment
# (EXO_MACSIGN_P12_BASE64, _P12_PASSWORD, _ASC_KEY_P8_BASE64, _ASC_KEY_ID,
# _ASC_ISSUER, _TEAM_ID: Roadrunner's secrets), else files in $SIGNING,
# present and private to this account. From the environment they are written
# once into $work/signing (0700, files 0600, deleted with $work however the run
# ends) and unset, so the build and everything else this run starts never
# sees them. Never printed, copied or sent anywhere; release/package-app.sh
# hands them to rcodesign and notarytool, and to nothing else.
if [ -n "${EXO_MACSIGN_P12_BASE64:-}" ] || [ -n "${EXO_MACSIGN_ASC_KEY_P8_BASE64:-}" ]; then
  for var in EXO_MACSIGN_P12_BASE64 EXO_MACSIGN_P12_PASSWORD EXO_MACSIGN_ASC_KEY_P8_BASE64 EXO_MACSIGN_ASC_KEY_ID EXO_MACSIGN_ASC_ISSUER; do
    [ -n "${!var+set}" ] || fail "$var is not set; with EXO_MACSIGN_* from the environment, all of them are needed"
  done
  env_key_id="$(printf '%s' "$EXO_MACSIGN_ASC_KEY_ID" | tr -d ' \t\r\n')"
  case "$env_key_id" in "" | *[!A-Za-z0-9]*) fail "EXO_MACSIGN_ASC_KEY_ID is not an App Store Connect key id" ;; esac
  SIGNING="$work/signing"
  (
    umask 077
    mkdir -p "$SIGNING"
    decode() { case "$1" in -----BEGIN*) printf '%s\n' "$1" ;; *) printf '%s' "$1" | tr -d ' \t\r\n' | base64 --decode ;; esac; }
    decode "$EXO_MACSIGN_P12_BASE64" > "$SIGNING/developer-id-application.p12" 2> /dev/null || exit 1
    printf '%s' "$EXO_MACSIGN_P12_PASSWORD" > "$SIGNING/p12-password"
    decode "$EXO_MACSIGN_ASC_KEY_P8_BASE64" > "$SIGNING/AuthKey_$env_key_id.p8" 2> /dev/null || exit 1
    printf '%s' "$env_key_id" > "$SIGNING/asc-key-id"
    printf '%s' "$EXO_MACSIGN_ASC_ISSUER" | tr -d ' \t\r\n' > "$SIGNING/asc-issuer"
    if [ -n "${EXO_MACSIGN_TEAM_ID:-}" ]; then printf '%s' "$EXO_MACSIGN_TEAM_ID" | tr -d ' \t\r\n' > "$SIGNING/team-id"; fi
  ) || fail "EXO_MACSIGN_P12_BASE64 or EXO_MACSIGN_ASC_KEY_P8_BASE64 is not valid base64"
  unset EXO_MACSIGN_P12_BASE64 EXO_MACSIGN_P12_PASSWORD EXO_MACSIGN_ASC_KEY_P8_BASE64 \
    EXO_MACSIGN_ASC_KEY_ID EXO_MACSIGN_ASC_ISSUER EXO_MACSIGN_TEAM_ID
  note "signing  EXO_MACSIGN_* from the environment (0600 files in this run's private folder)"
else
  note "signing  $SIGNING"
fi
private() {
  [ -f "$1" ] || fail "missing $1 (docs/releasing.md › Credentials)"
  local mode
  mode="$(stat -f %Lp "$1")"
  [ "$mode" = 600 ] || [ "$mode" = 400 ] || fail "$1 is mode $mode; it must be 0600"
}
setting() { # setting ENV_VAR FILE: the variable, else the file
  if [ -n "${!1:-}" ]; then printf '%s' "${!1}" | tr -d ' \t\r\n'; elif [ -f "$SIGNING/$2" ]; then tr -d ' \t\r\n' < "$SIGNING/$2"; fi
}
notary_key_id="$(setting EXO_MACSIGN_ASC_KEY_ID asc-key-id)"
notary_issuer="$(setting EXO_MACSIGN_ASC_ISSUER asc-issuer)"
[ -n "$notary_key_id" ] || fail "no App Store Connect key id: EXO_MACSIGN_ASC_KEY_ID or $SIGNING/asc-key-id"
[ -n "$notary_issuer" ] || fail "no App Store Connect issuer: EXO_MACSIGN_ASC_ISSUER or $SIGNING/asc-issuer"
private "$SIGNING/developer-id-application.p12"
private "$SIGNING/p12-password"
private "$SIGNING/AuthKey_$notary_key_id.p8"

requirement="$(git show "$commit:release/designated-requirement.txt" | tr -d '\n')"
# The requirement accepts the team of the certificate in release/; that the
# .p12 holds that certificate, release/package-app.sh checks before it signs.
want="$(git show "$commit:release/exowatt-developer-id.cer" | shasum -a 1 | cut -d' ' -f1)"
team="$(git show "$commit:release/exowatt-developer-id.cer" | openssl x509 -inform der -noout -subject | sed -n 's/.*OU *= *\([0-9A-Z]*\).*/\1/p')"
case "$requirement" in
  *"certificate leaf[subject.OU] = \"$team\""*) ;;
  *) fail "release/designated-requirement.txt does not accept release/exowatt-developer-id.cer's team (${team:-none})" ;;
esac
have="$(openssl pkcs12 -in "$SIGNING/developer-id-application.p12" -passin "file:$SIGNING/p12-password" -nokeys -clcerts 2> /dev/null \
  | openssl x509 -outform der 2> /dev/null | shasum -a 1 | cut -d' ' -f1)"
[ "$have" = "$want" ] || fail "the .p12 does not hold release/exowatt-developer-id.cer ($want). Renewed? See docs/releasing.md."
note "team     $team (certificate $want)"

# Every tag and release in the repository, drafts included: "<tag> <target> <draft>".
tags="$(gh api --paginate "repos/$REPO/tags?per_page=100" --jq '.[].name')"
releases="$(gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[] | "\(.tag_name) \(.target_commitish) \(.draft)"')"
existing="$(
  { printf '%s\n' "$tags"; printf '%s\n' "$releases" | cut -d' ' -f1; } \
    | sed -n -E 's/^v([0-9]+\.[0-9]+\.[0-9]{8}\.[0-9]+)$/\1/p' | sort -u -V
)"
latest="$(printf '%s\n' "$existing" | tail -1)"
highest="$(printf '%s\n' "$existing" | sed -E 's/.*\.//' | sort -n | tail -1)"
# A commit is released once: a run started again after it published (a
# pipeline rerun, the tag event its own release fires) has nothing to do.
released="$(printf '%s\n' "$releases" | awk -v c="$commit" '$2 == c && $3 == "false" { print $1; exit }')"
if [ -n "$released" ] && ! $dry_run && ! $again && { [ -z "$version" ] || [ "v$version" = "$released" ]; }; then
  step "$commit is already released: $released"
  note "https://github.com/$REPO/releases/tag/$released (--again releases it once more, as a new version)"
  rm -f "$OUT_ROOT/commits/$commit"
  exit 0
fi
# A run of this commit that stopped before publishing took a version and
# left its state in <out>/<version>: carry on with that version.
pointer="$OUT_ROOT/commits/$commit"
resuming=false
if ! $dry_run && [ -z "$reuse" ] && [ -f "$pointer" ]; then
  previous="$(tr -d '[:space:]' < "$pointer")"
  if $fresh; then
    note "--fresh: not carrying on from $previous"
  elif { [ -z "$version" ] || [ "$version" = "$previous" ]; } && [ -f "$OUT_ROOT/$previous/commit" ] \
    && [ "$(cat "$OUT_ROOT/$previous/commit")" = "$commit" ]; then
    version="$previous"
    resuming=true
    note "resume   a run of $commit stopped before publishing $previous; carrying on ($OUT_ROOT/$previous)"
  fi
fi
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
tag_ok=false
if printf '%s\n' "$existing" | grep -qxF "$version"; then
  # The one tag that may be there already: one pushed to start this release
  # (Roadrunner's tag event), on this commit, with no release yet.
  # Or a draft of this commit's release that a stopped publish left: it goes
  # before the release is made again.
  tag_commit="$(printf '%s\n' "$tags" | grep -qxF "$tag" && gh api "repos/$REPO/commits/$tag" --jq .sha 2> /dev/null || true)"
  release_line="$(printf '%s\n' "$releases" | awk -v t="$tag" '$1 == t { print; exit }')"
  if { [ -z "$tag_commit" ] || [ "$tag_commit" = "$commit" ]; } \
    && { [ -z "$release_line" ] || [ "$release_line" = "$tag $commit true" ]; }; then
    tag_ok=true
    if [ -n "$release_line" ]; then note "draft    $tag is a draft of $commit's release a stopped run left: this run replaces it"; fi
    if [ -n "$tag_commit" ]; then note "tag      $tag is there, on $commit, with no release: this run makes it"; fi
  else
    fail "$tag already exists in $REPO"
  fi
fi
# The updater, the installer and the tap only ever move forward.
latest="$(printf '%s\n' "$existing" | { grep -vxF "$version" || true; } | tail -1)"
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
  ! $resuming || fail "$version, the version a stopped run of $commit took, no longer sorts above the latest release, $latest: --fresh starts over with a new one"
  $dry_run || fail "$version does not sort above the latest release, $latest"
  note "dry run: $version sorts below the latest release, $latest"
fi
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
zip_name="copper-${version}-macos-arm64.zip"
x86_64_zip_name="copper-${version}-macos-x86_64.zip"
note "version  $version ($tag; latest is ${latest:-none})"
if $preflight; then
  note "mode     preflight: the checks only, nothing is built"
elif $dry_run && ! $notarize; then
  note "mode     dry run: signed, not notarized; nothing is tagged, released or uploaded"
elif $dry_run; then
  note "mode     dry run, notarized: nothing is tagged, released or uploaded"
else
  note "mode     PUBLISH"
fi

if $dry_run; then out="$OUT_ROOT/dry-run/$version"; else out="$OUT_ROOT/$version"; fi
assets="$out/assets"
logs="$out/logs"
job=""
on_mini=false
here_job=""

# Whatever happens: nothing of ours keeps running on the mini, its job folder
# and the throwaway worlds go, and so do the build folder and the scratch
# folder here.
packing=()  # the package-app.sh jobs running in the background, if any
cleanup() {
  local status=$?
  set +e
  # A CPU still packaging when the other failed (or on ^C): stop it.
  for pid in ${packing[@]+"${packing[@]}"}; do
    kill "$pid" 2> /dev/null
  done
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
      echo "    removed $where:$job"
    else
      echo "release-local: could not remove $where:$job — delete it by hand" >&2
    fi
  fi
  if [ -n "$here_job" ]; then
    rm -rf "$here_job"
    echo "    removed $here_job"
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# What release/package-app.sh signs with, from this commit: the script, the
# requirement, the certificate, the profile tool and Copper.entitlements.
mkdir -p "$work/src"
git archive --format=tar "$commit" release Copper.entitlements | tar -x -C "$work/src"

# The provisioning profile, once for both apps: the newest active Developer ID
# profile App Store Connect has for the App ID, else the one in $SIGNING.
key_file="$SIGNING/AuthKey_$notary_key_id.p8"
profile="$work/embedded.provisionprofile"
if $resuming && [ -f "$out/state/embedded.provisionprofile" ]; then
  # What the stopped run signed with: the same profile, whatever App Store
  # Connect would hand out now.
  cp "$out/state/embedded.provisionprofile" "$profile"
  : > "$work/profile.log"
  note "profile  the one the stopped run signed with ($out/state)"
elif ! python3 "$work/src/release/provisioning.py" fetch --key "$key_file" --key-id "$notary_key_id" --issuer "$notary_issuer" \
  --bundle-id "$BUNDLE_ID" --team "$team" --cert-sha1 "$want" --out "$profile" 2> "$work/profile.log"; then
  [ -f "$SIGNING/Copper_Developer_ID.provisionprofile" ] || { cat "$work/profile.log" >&2; fail "no profile from App Store Connect, and no $SIGNING/Copper_Developer_ID.provisionprofile"; }
  cp "$SIGNING/Copper_Developer_ID.provisionprofile" "$profile"
  note "profile  App Store Connect could not be asked; $SIGNING/Copper_Developer_ID.provisionprofile"
fi
sed 's/^/    /' "$work/profile.log"
python3 "$work/src/release/provisioning.py" check --profile "$profile" --bundle-id "$BUNDLE_ID" --team "$team" --cert-sha1 "$want" \
  || fail "the provisioning profile can't sign $BUNDLE_ID (docs/releasing.md › The provisioning profile)"
python3 "$work/src/release/provisioning.py" entitlements --base "$work/src/Copper.entitlements" --profile "$profile" \
  --bundle-id "$BUNDLE_ID" --team "$team" --out "$work/entitlements.plist" 2>&1 | sed 's/^/    /'
profile_uuid="$(python3 "$work/src/release/provisioning.py" uuid --profile "$profile")"
# The signer: COPPER_RCODESIGN, else an rcodesign 0.29.0 on PATH (the
# agent's), else the pinned download (release/rcodesign.sh).
rcodesign="${COPPER_RCODESIGN:-$("$work/src/release/rcodesign.sh")}"
note "signer   $("$rcodesign" --version) ($rcodesign)"

# ---------------------------------------------------------------------------
# The folder on the mini: the launch check's, and the build's unless it is here.
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
# The external disk can hang whoever lists it (see REMOTE_DIR); not even df goes there.
case "$remote_dir" in
  /Volumes/*) fail "COPPER_RELEASE_REMOTE_DIR is on an external disk ($remote_dir); use the mini's internal one, e.g. '~/sign-builds/copper'" ;;
esac
# --here: the build is here too, in the same folder.
if $here && [ -z "$BUILD_HERE" ]; then BUILD_HERE="$remote_dir"; fi
remote_free_gb=$LAUNCH_FREE_GB
[ -n "$BUILD_HERE" ] || [ -n "$reuse" ] || { $resuming && [ -f "$out/build/.built" ]; } || remote_free_gb=$BUILD_FREE_GB
# The disk it is on, or will be: the nearest folder of it that exists.
free_kb="$(mini 60 "d='$remote_dir'; while [ ! -d \"\$d\" ]; do d=\"\$(dirname \"\$d\")\"; done; df -k \"\$d\" | awk 'NR == 2 { print \$4 }'")"
free_gb="$(awk -v k="$free_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"
note "disk     $free_gb GB free for $remote_dir ($where)"
[ "$free_kb" -ge $((remote_free_gb * 1024 * 1024)) ] \
  || fail "$where has $free_gb GB free for $remote_dir; this release wants $remote_free_gb there"
if [ -n "$BUILD_HERE" ]; then
  # shellcheck disable=SC2088  # a literal ~/, as the variable may hold it
  case "$BUILD_HERE" in "~/"*) BUILD_HERE="$HOME/${BUILD_HERE#"~/"}" ;; esac
  case "$BUILD_HERE" in /*) ;; *) fail "COPPER_RELEASE_BUILD_HERE must be absolute or start with ~/, got: $BUILD_HERE" ;; esac
  # The disk it is on, or will be (preflight makes no folder).
  d="$BUILD_HERE"
  while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  here_free_kb="$(df -k "$d" | awk 'NR == 2 { print $4 }')"
  note "here     $(awk -v k="$here_free_kb" 'BEGIN { printf "%.1f", k / 1048576 }') GB free for $BUILD_HERE"
  [ "$here_free_kb" -ge $((BUILD_FREE_GB * 1024 * 1024)) ] || fail "$BUILD_HERE has less than $BUILD_FREE_GB GB free"
fi
if $preflight; then
  step "Preflight only: everything checks out for $tag; nothing was built"
  exit 0
fi

# Only now: a run that stopped in preflight leaves the last one's output be.
if [ -n "$reuse" ]; then
  for arch in arm64 x86_64; do
    for file in "assets/copper-$version-macos-$arch.zip" "assets/copper-$version-macos-$arch.dmg" \
      "assets/copper-$version-macos-$arch.zip.sha256" "assets/copper-$version-macos-$arch.dmg.sha256" "logs/package-$arch.out"; do
      [ -s "$out/$file" ] || fail "--reuse-assets: no $out/$file"
    done
    (cd "$assets" && shasum -a 256 -c "copper-$version-macos-$arch.zip.sha256" "copper-$version-macos-$arch.dmg.sha256" > /dev/null) \
      || fail "--reuse-assets: the $arch assets are not the ones their .sha256 name"
  done
  rm -f "$assets/copper-version.json" "$assets"/*.dSYM.zip
elif $resuming; then
  mkdir -p "$assets" "$logs"
  rm -f "$assets/copper-version.json" "$assets"/*.dSYM.zip
else
  rm -rf "$out"
  mkdir -p "$assets" "$logs"
  printf '%s\n' "$commit" > "$out/commit"
  mkdir -p "$out/state"
  cp "$profile" "$out/state/embedded.provisionprofile"
  # The version this commit's release takes, until it is published.
  if ! $dry_run; then
    mkdir -p "$OUT_ROOT/commits"
    printf '%s\n' "$version" > "$pointer"
  fi
fi
stamp="$version-$(date -u +%H%M%S)-$$"
job="$remote_dir/$stamp"
on_mini=true
mini 60 mkdir -p "$job"
note "job      $where:$job"

cat > "$work/build.sh" <<'BUILD'
#!/bin/bash
# The workflow's three build steps, with its assertions, in <job>/src:
#   build.sh <job> <free GB> <floor GB>
# Everything the build writes stays in <job>: HOME and TMPDIR point into it,
# so SwiftPM's and the compilers' caches go when the job folder goes. It
# starts only with <free GB> free (checked once it holds the lock, since it
# may have waited for it), and is stopped if the disk drops under <floor GB>.
set -euo pipefail
job="$1" floor_kb=$(($3 * 1024 * 1024))
cd "$job/src"
fail() { echo "error: $*" >&2; exit 1; }
free="$(df -k "$job" | awk 'NR == 2 { print $4 }')"
[ "$free" -ge $(($2 * 1024 * 1024)) ] || fail "$((free / 1024)) MB free on the build's disk; a build wants $2 GB"
mkdir -p "$job/home" "$job/tmp"
export HOME="$job/home" TMPDIR="$job/tmp/"
caches="$(getconf DARWIN_USER_CACHE_DIR 2> /dev/null || true)"
before="$(ls "$caches" 2> /dev/null || true)"
# Nothing the build runs needs a GitHub token.
unset GH_TOKEN GITHUB_TOKEN
# The Xcode DEVELOPER_DIR names (a Roadrunner agent sets it), else the full
# Xcode when there is one; the Command Line Tools build Copper too.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# With SEARCH_SIGN_IDENTITY empty, build.sh asks the keychain for a Developer
# ID. A release never wants one (release/package-app.sh signs it again), and
# this path touches no keychain, so build.sh gets a `security` that finds
# nothing: its ad-hoc signature, as on the runner.
mkdir -p "$job/no-keychain"
printf '#!/bin/sh\nexit 0\n' > "$job/no-keychain/security"
chmod 755 "$job/no-keychain/security"
export PATH="$job/no-keychain:$PATH"

echo "--- toolchain"
xcrun --show-sdk-version
swift --version

# Job control: the steps below run in a process group of their own, which the
# watch can stop whole (swift-build and every compiler it started).
set -m
(

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
) &
steps=$!
low=false
while kill -0 "$steps" 2> /dev/null; do
  free="$(df -k "$job" | awk 'NR == 2 { print $4 }')"
  if [ "$free" -lt "$floor_kb" ]; then
    echo "error: $((free / 1024)) MB free on the build's disk, under the floor of $3 GB: stopping the build" >&2
    low=true
    kill -TERM -- "-$steps" 2> /dev/null || true
    sleep 5
    kill -KILL -- "-$steps" 2> /dev/null || true
    break
  fi
  sleep 10
done
status=0
wait "$steps" || status=$?
# The compilers' caches the build made outside the job folder, if any (only
# compiler-named ones that were not there before).
for made in $(comm -13 <(printf '%s\n' "$before" | sort) <(ls "$caches" 2> /dev/null | sort)); do
  case "$made" in
    clang | org.llvm.* | org.swift.* | com.apple.DeveloperTools | swift*) rm -rf "${caches:?}/$made" ;;
  esac
done
$low && exit 1
[ "$status" = 0 ] || exit "$status"
echo "--- built"
BUILD

# The apps and dSYMs: in <out>/build, so a run that stops after the build
# carries on from them (deleted once the release is out).
built="$out/build"
mkdir -p "$built"
if [ -n "$reuse" ]; then
  step "Reuse the signed, notarized assets of $commit"
  note "no build and no signing: the dSYMs went with that run's unsigned build"
else
if $resuming && [ -f "$built/.built" ]; then
  step "Carry on with the apps built for $version ($built)"
elif [ -n "$BUILD_HERE" ]; then
  rm -rf "$built" && mkdir -p "$built"
  step "Build here ($BUILD_HERE)"
  here_job="$BUILD_HERE/$stamp"
  mkdir -p "$here_job/src"
  note "job      $here_job"
  # Exactly the commit's tree: nothing uncommitted, nothing ignored.
  git archive --format=tar "$commit" | tar -x -C "$here_job/src"
  # One heavy job at a time on this Mac, and never ahead of what someone is doing on it.
  note "waiting for $LOCK"
  nice -n 10 /usr/bin/lockf -t 10800 "$LOCK" bash "$work/build.sh" "$here_job" "$BUILD_FREE_GB" "$BUILD_FLOOR_GB" < /dev/null 2>&1 | tee "$logs/build.log"
  # shellcheck disable=SC2046  # names without spaces, only those that exist
  (cd "$here_job/src/build" && COPYFILE_DISABLE=1 tar -cf - $(ls -d Copper.app Copper.app.dSYM x86_64/Copper.app x86_64/Copper.app.dSYM 2> /dev/null)) \
    | tar -x -C "$built"
  note "the build used $(du -sk "$here_job" | awk '{ printf "%.1f", $1 / 1048576 }') GB"
  # The sources and the build products (gigabytes) are done with.
  rm -rf "$here_job"
  here_job=""
else
  rm -rf "$built" && mkdir -p "$built"
  step "Build on the Mac mini ($MINI)"
  mini 60 mkdir -p "$job/src"
  git archive --format=tar "$commit" | mini 600 tar -x -C "$job/src"
  mini 60 "cat > '$job/build.sh'" < "$work/build.sh"
  # The build streams here and into logs/; the mini is shared, so one build at a time.
  # shellcheck disable=SC2029  # the mini's shell expands nothing in it: the paths are quoted
  mini 14400 "nice -n 10 /usr/bin/lockf -t 10800 '$LOCK' bash '$job/build.sh' '$job' '$BUILD_FREE_GB' '$BUILD_FLOOR_GB'" < /dev/null 2>&1 | tee "$logs/build.log"
  step "Bring the unsigned apps and dSYMs back"
  # Only the bundles; COPYFILE_DISABLE keeps the mini's tar from adding ._ files.
  mini 900 "cd '$job/src/build' && COPYFILE_DISABLE=1 tar -cf - \$(ls -d Copper.app Copper.app.dSYM x86_64/Copper.app x86_64/Copper.app.dSYM 2> /dev/null)" \
    | tar -x -C "$built"
  note "the build used $(mini 120 "du -sk '$job' | awk '{ printf \"%.1f\", \$1 / 1048576 }'") GB on the mini"
  # The sources, the build products and the caches are gigabytes on a shared
  # disk: all of it goes now. The launch check brings its own files.
  mini 300 rm -rf "$job"
  mini 30 "test ! -e '$job'" || fail "could not remove $MINI:$job"
  note "removed $MINI:$job"
fi
for app in "$built/Copper.app" "$built/x86_64/Copper.app"; do
  [ -x "$app/Contents/MacOS/Copper" ] || fail "missing $app"
done
touch "$built/.built"

# ---------------------------------------------------------------------------
if $notarize; then
  step "Stamp $version, sign, notarize, staple, zip, disk image (release/package-app.sh)"
else
  step "Stamp $version, sign, zip, disk image; not notarized (release/package-app.sh)"
fi

# The dSYMs stay with the unsigned build: signing keeps LC_UUID, so they
# still name the shipped binaries. The two CPUs are packaged side by side:
# each waits on Apple's notary service twice (the app, then the disk image
# made from the stapled app), which can take hours on a slow day. Both share
# one deadline (COPPER_NOTARY_HOURS from now, default 4); past it with Apple
# still working, this run stops with 75 and keeps everything in $out/state,
# and the next run of this commit waits on the same submissions.
export COPPER_NOTARY_DEADLINE="${COPPER_NOTARY_DEADLINE:-$(($(date +%s) + ${COPPER_NOTARY_HOURS:-4} * 3600))}"
if $notarize; then
  note "notary   waiting on Apple until $(date -r "$COPPER_NOTARY_DEADLINE" '+%H:%M %Z') at the latest"
fi
notarize_flag=1
$notarize || notarize_flag=0
for arch in arm64 x86_64; do
  app="$built/Copper.app"
  [ "$arch" = arm64 ] || app="$built/$arch/Copper.app"
  COPPER_PROFILE="$profile" COPPER_RCODESIGN="$rcodesign" EXO_MACSIGN_CONFIG_DIR="$SIGNING" \
    COPPER_NOTARIZE="$notarize_flag" COPPER_PACKAGE_STATE="$out/state/$arch" \
    bash "$work/src/release/package-app.sh" "$app" "$version" "$assets" "$arch" \
    > "$logs/package-$arch.out" 2> "$logs/package-$arch.log" &
  packing+=("$!")
done
packed=(arm64 x86_64)  # the order packing was started in (bash 3.2: no associative arrays)
waiting=""
for i in 0 1; do
  arch="${packed[$i]}"
  code=0
  wait "${packing[$i]}" || code=$?
  case "$code" in
    0) ;;
    75) waiting="$waiting $arch" ;;
    *) tail -40 "$logs/package-$arch.log" >&2; fail "release/package-app.sh failed for $arch ($logs/package-$arch.log)" ;;
  esac
done
packing=()
if [ -n "$waiting" ]; then
  grep -h '^notary' "$logs"/package-*.log | sed 's/^/    /'
  step "Apple is still notarizing ($waiting ): stopping here, nothing published"
  note "everything is kept in $out; run this again on $commit and it carries on with $version,"
  note "waiting on the same submissions (it never sends Apple the same bytes twice)"
  exit 75
fi
fi
for arch in arm64 x86_64; do
  sed 's/^/    /' "$logs/package-$arch.log" | grep -v '^    $' | grep -E '^    (profile|  claims|  not claimed|  allowed|signed|notary|stamped|packed)' || true
  grep -q "^profile=$profile_uuid\$" "$logs/package-$arch.out" || fail "$arch: package-app.sh did not embed profile $profile_uuid"
  printf -v "notary_$arch" '%s' "$(sed -n 's/^notary_id=//p' "$logs/package-$arch.out")"
  printf -v "dmg_notary_$arch" '%s' "$(sed -n 's/^dmg_notary_id=//p' "$logs/package-$arch.out")"
done
has_cli="$(sed -n 's/^has_cli=//p' "$logs/package-arm64.out")"
notary_arm64="${notary_arm64:-}" dmg_notary_arm64="${dmg_notary_arm64:-}"
notary_x86_64="${notary_x86_64:-}" dmg_notary_x86_64="${dmg_notary_x86_64:-}"
sha256="$(cut -d' ' -f1 < "$assets/$zip_name.sha256")"
x86_64_sha256="$(cut -d' ' -f1 < "$assets/$x86_64_zip_name.sha256")"
# Stable names for releases/latest/download/… (installer, site).
for arch in arm64 x86_64; do
  for kind in zip dmg; do
    cp "$assets/copper-${version}-macos-${arch}.$kind" "$assets/copper-macos-${arch}.$kind"
    printf '%s  copper-macos-%s.%s\n' "$(cut -d' ' -f1 < "$assets/copper-${version}-macos-${arch}.$kind.sha256")" "$arch" "$kind" \
      > "$assets/copper-macos-${arch}.$kind.sha256"
  done
done
git show "$commit:release/copper-install.sh" > "$assets/copper-install.sh"

# ---------------------------------------------------------------------------
step "Check the signature (the shipped zips and disk images)"

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
  dr="$(codesign -d -r- "$app" 2> /dev/null | sed -n 's/^designated => //p' | sed 's: /\* exists \*/::g')"
  echo "designated => $dr"
  [ "$dr" = "$requirement" ] || fail "$arch: designated requirement is '$dr', expected '$requirement'"
  # The updater's own two checks, argument for argument (Updates.swift, then
  # Signing.unsatisfied): integrity alone, and the requirement.
  codesign --verify --deep --strict "$app" || fail "$arch: codesign --verify --deep --strict failed"
  codesign --verify --deep --strict -R "=$requirement" "$app" || fail "$arch: does not satisfy $requirement"
  details="$(codesign -dvv "$app" 2>&1)"
  printf '%s\n' "$details" | grep -E '^(Identifier|Format|CodeDirectory|Authority|Signature|Timestamp|TeamIdentifier|Runtime|Sealed)' || true
  # The hardened runtime and no other flags, Apple's timestamp, the Developer ID.
  printf '%s\n' "$details" | grep -q '^CodeDirectory .* flags=0x10000(runtime) ' || fail "$arch: the flags are not the hardened runtime alone"
  printf '%s\n' "$details" | grep -q '^Timestamp=' || fail "$arch: no secure timestamp"
  printf '%s\n' "$details" | grep -q "^Authority=Developer ID Application: .*($team)\$" || fail "$arch: not signed by a Developer ID of team $team"
  # The profile is this run's, and the entitlements are Copper.entitlements
  # and what it allows (release/provisioning.py), no more, no less.
  cmp -s "$app/Contents/embedded.provisionprofile" "$profile" || fail "$arch: Contents/embedded.provisionprofile is not profile $profile_uuid"
  codesign -d --entitlements - --xml "$app" 2> /dev/null > "$work/entitlements-$arch.plist"
  python3 -c 'import plistlib, sys; a, b = (plistlib.load(open(f, "rb")) for f in sys.argv[1:]); sys.exit(a != b)' \
    "$work/entitlements.plist" "$work/entitlements-$arch.plist" || fail "$arch: entitlements are not Copper.entitlements and the profile's"
  # Notarized and stapled: Gatekeeper opens it, offline too.
  if $notarize; then
    xcrun stapler validate "$app" > /dev/null || fail "$arch: no valid stapled ticket"
    assessment="$(spctl -a -vvv -t exec "$app" 2>&1 || true)"
    echo "$assessment"
    case "$assessment" in
      *"accepted"*"source=Notarized Developer ID"*) ;;
      *) fail "$arch: Gatekeeper does not accept it as a notarized Developer ID app" ;;
    esac
  else
    echo "not notarized (dry run): no ticket, Gatekeeper not asked"
  fi
  cdhash="$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  echo "cdhash $cdhash"

  # The disk image: signed by the same Developer ID, its own ticket stapled,
  # Gatekeeper opens it, and the app inside is the zip's, byte for byte.
  dmg="$assets/copper-${version}-macos-${arch}.dmg"
  codesign --verify --strict "$dmg" || fail "$arch: the disk image's signature does not verify"
  # Into a variable first: grep -q stops reading at the match, and codesign,
  # still writing, would fail the pipeline (pipefail) on a good disk image.
  dmg_details="$(codesign -dvv "$dmg" 2>&1)"
  printf '%s\n' "$dmg_details" | grep -q "^Authority=Developer ID Application: .*($team)\$" || fail "$arch: the disk image is not signed by team $team"
  if $notarize; then
    xcrun stapler validate "$dmg" > /dev/null || fail "$arch: no valid stapled ticket on the disk image"
    assessment="$(spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 || true)"
    echo "$assessment"
    case "$assessment" in
      *"accepted"*"source=Notarized Developer ID"*) ;;
      *) fail "$arch: Gatekeeper does not accept the disk image as notarized Developer ID" ;;
    esac
  fi
  mount="$work/mount-$arch"
  mkdir -p "$mount"
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg"
  inside="$(codesign -dvvv "$mount/Copper.app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  diff -rq "$mount/Copper.app" "$app" > /dev/null 2>&1 && same=true || same=false
  [ -L "$mount/Applications" ] && apps=true || apps=false
  hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount"
  { [ "$inside" = "$cdhash" ] && $same; } || fail "$arch: the app in the disk image is not the zip's"
  $apps || fail "$arch: the disk image has no Applications shortcut"
  if $notarize; then echo "disk image: the zip's app (cdhash $inside), stapled"; else echo "disk image: the zip's app (cdhash $inside)"; fi
done

# ---------------------------------------------------------------------------
step "Zip the dSYMs"

# The release binary ships stripped; this is what names its crash reports.
# Only attached when its UUID is the shipped binary's (signing keeps LC_UUID) —
# a dSYM that doesn't match would only mislead. Missing is a warning, as in
# build.sh and the workflow.
for arch in arm64 x86_64; do
  app="$built/Copper.app"
  [ "$arch" = arm64 ] || app="$built/$arch/Copper.app"
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
# The updater and the tap read this shape: hold it to the published one, so a
# field never goes missing or changes type between releases.
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
  || fail "copper-version.json does not have the published manifest's fields (changed on purpose? then both readers must take the new shape first)"
note "copper-version.json has the published manifest's fields, in its order"
(cd "$assets" && shasum -a 256 ./*)

# ---------------------------------------------------------------------------
launching=true
if $here && ! launchctl print "gui/$(id -u)" > /dev/null 2>&1; then
  # A Roadrunner agent is a LaunchDaemon: no login session, no window server,
  # so no app can start. The signature checks above are what it can do.
  launching=false
  step "Launch check skipped: this account has no login session here (a CI agent)"
  note "the signature, requirement, entitlements and Gatekeeper checks above still ran"
elif $here; then
  step "Launch the shipped apps here (headless, throwaway worlds)"
else
  step "Launch the shipped apps on the mini (headless, throwaway worlds)"
fi

if $launching; then
mini 60 mkdir -p "$job/launch"
COPYFILE_DISABLE=1 tar -C "$assets" -cf - "$zip_name" "$x86_64_zip_name" | mini 600 tar -x -C "$job/launch"
mini 60 "cat > '$job/launch.sh'" <<'REMOTE'
#!/bin/bash
# A signed release must start like any other: open the unzipped bundle
# headless in a world of its own (its own folder and settings: a throwaway
# profile) and ask it its version.
set -euo pipefail
job="$1" version="$2"
fail() { echo "error: $*" >&2; exit 1; }
# Nobody is at this Mac, but someone is logged in, and an app has to start in
# that session: `open` from ssh has no window server (LaunchServices answers
# -10810) and `launchctl asuser` needs root. A one-shot agent in the session's
# own launchd domain runs `open` there instead. The two unzipped apps go in
# this user's temporary folder, and are deleted with the job.
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
  # What AMFI (the kernel's code-signing check and amfid) said about it. An
  # entitlement the embedded profile doesn't allow gets the app killed at
  # launch, so a /health answer already says it passed; this is the record.
  log show --last 3m --style compact \
    --predicate 'process == "amfid" OR subsystem == "com.apple.MobileFileIntegrity" OR sender == "AppleMobileFileIntegrity"' 2> /dev/null \
    | grep -F "$app" | sed "s/^/  amfi: /" | tail -20 || true
  echo "$arch: amfi: no rejection of $app"
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
fi

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

or download the disk image or zip for your Mac below — \`copper-${version}-macos-arm64.dmg\` / \`${zip_name}\` for Apple Silicon, \`copper-${version}-macos-x86_64.dmg\` / \`${x86_64_zip_name}\` for Intel — and move Copper.app to /Applications (signed with Exowatt Inc's Developer ID, team ${team}, and notarized by Apple).

macOS 14 Sonoma or later, Apple Silicon or Intel. Already installed? Copper updates itself — Settings › Updates.

sha256 \`${sha256}\` (arm64)
sha256 \`${x86_64_sha256}\` (x86_64)
EOF
# A note for this release alone (release/release-note.md at this commit), above the rest.
if git cat-file -e "$commit:release/release-note.md" 2> /dev/null; then
  { git show "$commit:release/release-note.md"; echo; cat "$out/release-notes.md"; } > "$work/release-notes.md"
  mv "$work/release-notes.md" "$out/release-notes.md"
fi

# ---------------------------------------------------------------------------
if $dry_run; then
  step "Dry run: nothing published"
  note "no tag, no release, no upload — what would ship is in $assets"
else
  step "Publish $tag"
  # The build took a while; another run may have taken this number since. A
  # tag or draft of this commit's release that was there at the start is ours.
  now_tag="$(gh api "repos/$REPO/git/ref/tags/$tag" --jq .object.sha 2> /dev/null || true)"
  now_release="$(gh api "repos/$REPO/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | \"\(.target_commitish) \(.draft) \(.id)\"" | head -1)"
  if [ -n "$now_tag" ] && ! $tag_ok; then
    fail "$tag appeared in $REPO during the build; nothing uploaded — run again for the next number"
  fi
  if [ -n "$now_release" ]; then
    case "$now_release" in
      "$commit true "*)
        note "deleting the draft a stopped publish of $tag left (release ${now_release##* })"
        gh api -X DELETE "repos/$REPO/releases/${now_release##* }"
        ;;
      *) fail "$tag has a release in $REPO now; nothing uploaded — run again for the next number" ;;
    esac
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
    "$assets/copper-${version}-macos-arm64.dmg" "$assets/copper-${version}-macos-arm64.dmg.sha256" \
    "$assets/copper-macos-arm64.dmg" "$assets/copper-macos-arm64.dmg.sha256" \
    "$assets/copper-${version}-macos-x86_64.dmg" "$assets/copper-${version}-macos-x86_64.dmg.sha256" \
    "$assets/copper-macos-x86_64.dmg" "$assets/copper-macos-x86_64.dmg.sha256" \
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
  for arch in arm64 x86_64; do
    verify "https://github.com/$REPO/releases/download/$tag/copper-${version}-macos-${arch}.dmg" \
      "$(cut -d' ' -f1 < "$assets/copper-${version}-macos-${arch}.dmg.sha256")"
  done
  verify "https://github.com/$REPO/releases/latest/download/copper-version.json" \
    "$(shasum -a 256 "$assets/copper-version.json" | cut -d' ' -f1)"

  # Published: the next run of this commit has nothing to carry on.
  rm -f "$pointer"
  rm -rf "$built" "$out/state"
  # COPPER_RELEASE_KEEP_ASSETS=0 (Roadrunner): the assets are on GitHub now.
  [ "${COPPER_RELEASE_KEEP_ASSETS:-1}" != 0 ] || rm -rf "$out"

  step "Point the Homebrew tap at $version (release/bump-tap.sh)"
  if [ "${COPPER_RELEASE_TAP:-1}" = 0 ]; then
    note "COPPER_RELEASE_TAP=0: left to the caller"
  elif ! bash "$work/src/release/bump-tap.sh" "$version"; then
    note "warning: the tap was not updated; the release is out. Run release/bump-tap.sh $version"
    tap_failed=true
  fi
fi
rm -rf "$built"

step "Copper $version"
if $dry_run; then
  note "dry run: nothing published (no tag, no release); the signed zips are in $assets"
else
  note "release: https://github.com/$REPO/releases/tag/$tag"
  if [ "${tap_failed:-false}" = true ]; then note "the tap is NOT updated: release/bump-tap.sh $version"; fi
fi
note "source: https://github.com/$REPO/commit/$commit"
note "sha256 (arm64): $sha256"
note "sha256 (x86_64): $x86_64_sha256"
note "signed: $requirement ($("$rcodesign" --version))"
note "profile: $profile_uuid; entitlements: $(python3 -c 'import plistlib, sys; print(", ".join(sorted(plistlib.load(open(sys.argv[1], "rb")))))' "$work/entitlements.plist")"
note "notary (arm64): app $notary_arm64, disk image $dmg_notary_arm64"
note "notary (x86_64): app $notary_x86_64, disk image $dmg_notary_x86_64"
note "CLI shim in bundle: $has_cli"
