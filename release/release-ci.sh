#!/bin/bash
# Roadrunner's Copper release (.woodpecker/release.yaml), on its macOS agent:
# release/release-local.sh --here, with the mode the pipeline asks for.
#
#   tag v<version> pushed                  publish <version> from the tagged commit
#   manual on fork, RELEASE=1              publish fork's commit as the next version
#   manual on fork, DRY_RUN=1              build and sign it; nothing goes to Apple
#                                          or GitHub (NOTARIZE=1: notarize it too)
#   (VERSION=<v> with RELEASE=1 or DRY_RUN=1 names the version; FRESH=1 starts over)
#
# A publishing run keeps what it makes in COPPER_RELEASE_OUT (default
# ~roadrunner/copper-release on the agent, outside the workspace Woodpecker
# deletes), so a run that stops — Apple still notarizing at the deadline, the
# pipeline's timeout, a lost agent connection — is carried on by restarting
# the pipeline (or a new one on the same commit): the same version, the same
# signed bytes, the same notary submissions, never sent twice; an already
# notarized pair is published as it is.
#
# Credentials (Woodpecker secrets, never in a file of the repo): EXO_MACSIGN_*
# (release/release-local.sh writes them into 0600 files in a private folder
# that goes with the run) and GH_TOKEN (exowatt-woodpecker-bot: the release
# and the tap).
set -euo pipefail

fail() { printf 'release-ci: %s\n' "$*" >&2; exit 1; }
cd "$(dirname "$0")/.."
root="$(pwd)"

# The agent's tools: Homebrew's gh and git, the pinned rcodesign and exo-macsign.
for dir in /opt/roadrunner/bin /opt/homebrew/bin; do
  case ":$PATH:" in *":$dir:"*) ;; *) [ ! -d "$dir" ] || PATH="$PATH:$dir" ;; esac
done
export PATH
# The Xcode the agent names; xcrun, notarytool and stapler come from it.
if [ -n "${DEVELOPER_DIR:-}" ]; then
  [ -d "$DEVELOPER_DIR" ] || fail "DEVELOPER_DIR is $DEVELOPER_DIR, which is not there"
elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# The signer: the agent's (EXO_MACSIGN_RCODESIGN), else release/rcodesign.sh's
# choice (an rcodesign 0.29.0 on PATH, else its pinned download).
if [ -z "${COPPER_RCODESIGN:-}" ] && [ -n "${EXO_MACSIGN_RCODESIGN:-}" ] && [ -x "$EXO_MACSIGN_RCODESIGN" ]; then
  export COPPER_RCODESIGN="$EXO_MACSIGN_RCODESIGN"
fi
[ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is not set (the github_release_token secret)"

event="${CI_PIPELINE_EVENT:-manual}"
args=(--here)
mode=""
case "$event" in
  tag)
    tag="${CI_COMMIT_TAG:?a tag event without CI_COMMIT_TAG}"
    case "$tag" in v[0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;; *) fail "$tag is not a release tag (v<VERSION>.<YYYYMMDD>.<n>)" ;; esac
    args+=(--version "${tag#v}")
    mode=publish
    ;;
  manual)
    if [ "${DRY_RUN:-}" = 1 ]; then
      args+=(--dry-run)
      [ "${NOTARIZE:-}" != 1 ] || args+=(--notarize)
      mode=dry-run
    elif [ "${RELEASE:-}" = 1 ]; then
      mode=publish
    else
      fail "a manual run needs RELEASE=1 (publish) or DRY_RUN=1 (build and sign only)"
    fi
    [ -z "${VERSION:-}" ] || args+=(--version "$VERSION")
    ;;
  *) fail "the release runs on a v… tag or a manual run, not on $event" ;;
esac
[ "${FRESH:-}" != 1 ] || args+=(--fresh)

# The build and launch folder: the workspace, which Woodpecker deletes.
export COPPER_RELEASE_REMOTE_DIR="${COPPER_RELEASE_REMOTE_DIR:-$root/build/release-jobs}"
if [ "$mode" = publish ]; then
  if [ -z "${COPPER_RELEASE_OUT:-}" ]; then
    agent_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{ print $2 }')"
    [ -n "$agent_home" ] && [ -w "$agent_home" ] || fail "no home folder to keep the release's state in; set COPPER_RELEASE_OUT"
    export COPPER_RELEASE_OUT="$agent_home/copper-release"
  fi
  mkdir -p "$COPPER_RELEASE_OUT"
  # Runs that never finished and were never carried on: gone after two weeks.
  find "$COPPER_RELEASE_OUT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -mtime +14 -exec rm -rf {} + 2> /dev/null || true
  find "$COPPER_RELEASE_OUT/commits" -type f -mtime +14 -delete 2> /dev/null || true
  # The tap is the pipeline's next step; the published assets live on GitHub.
  export COPPER_RELEASE_TAP=0 COPPER_RELEASE_KEEP_ASSETS=0
fi
# Apple's queue: wait until about 45 minutes before the pipeline's timeout
# (Woodpecker's repo timeout for copper-browser/Copper is 600 minutes), then
# stop with everything kept, to be carried on by a restart.
if [ -z "${COPPER_NOTARY_DEADLINE:-}" ] && [ -n "${CI_PIPELINE_STARTED:-}" ]; then
  export COPPER_NOTARY_DEADLINE=$((CI_PIPELINE_STARTED + ${COPPER_CI_TIMEOUT_MINUTES:-600} * 60 - 45 * 60))
fi

printf 'release-ci: %s, %s: release/release-local.sh %s\n' "$event" "$mode" "${args[*]}"
code=0
bash release/release-local.sh "${args[@]}" || code=$?
if [ "$code" = 75 ]; then
  fail "Apple is still notarizing. Nothing is lost: restart this pipeline (or run RELEASE=1 again on the same commit) and it waits on the same submissions"
fi
if [ "$mode" = dry-run ]; then
  # A dry run's apps and assets are only for this pipeline.
  rm -rf "$root/build/release-local" "$COPPER_RELEASE_REMOTE_DIR"
fi
exit "$code"
