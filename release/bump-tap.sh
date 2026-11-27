#!/bin/bash
# Point the Homebrew tap (copper-browser/homebrew-copper, Casks/copper.rb) at a
# published Copper release, through GitHub's contents API: no clone, no push.
#
#   release/bump-tap.sh [<version>]       default: the latest release
#
# The tap's own renderer does the work (scripts/bump.mjs at the tap's main:
# reads the release's copper-version.json, checks each zip's .sha256 sidecar
# against it, renders the cask), so the cask is exactly what the tap's bump
# would write. The new file is committed to main as one contents-API update,
# conditional on the file being what was read (a race with another writer
# fails, and the next run sees the new state). It never moves the tap back to
# an older version, and does nothing when the cask is already this release's.
#
# Token: GH_TOKEN (Roadrunner's github_release_token, exowatt-woodpecker-bot's;
# needs contents:write on the tap), else gh's own sign-in. The commit is
# exowatt-woodpecker-bot's when the token is the bot's, else the token owner's.
# Run by .woodpecker/release.yaml after the release, and by
# release/release-local.sh after a release cut by hand.
set -euo pipefail

TAP=copper-browser/homebrew-copper
REPO=copper-browser/Copper
CASK=Casks/copper.rb
fail() { printf 'bump-tap: %s\n' "$*" >&2; exit 1; }
say() { printf '    %s\n' "$*"; }

for tool in gh node curl base64; do
  command -v "$tool" > /dev/null || fail "needs $tool on PATH"
done
version="${1:-}"
if [ -z "$version" ]; then
  version="$(gh api "repos/$REPO/releases/latest" --jq .tag_name)"
  version="${version#v}"
fi
case "$version" in
  [0-9]*.[0-9]*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9]*) ;;
  *) fail "not a Copper version: $version" ;;
esac
tag="v$version"

work="$(mktemp -d "${TMPDIR:-/tmp}/copper-bump-tap.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The tap's renderer and cask, at its main.
mkdir -p "$work/tap/scripts" "$work/tap/Casks"
fetch() { # fetch PATH OUT [SHA_OUT]: one file of the tap at main
  gh api "repos/$TAP/contents/$1?ref=main" > "$work/file.json"
  node -e '
    const fs = require("fs");
    const f = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    fs.writeFileSync(process.argv[2], Buffer.from(f.content, "base64"));
    if (process.argv[3]) fs.writeFileSync(process.argv[3], f.sha);
  ' "$work/file.json" "$2" ${3:+"$3"}
}
fetch scripts/bump.mjs "$work/tap/scripts/bump.mjs"
fetch scripts/render-cask.mjs "$work/tap/scripts/render-cask.mjs"
fetch "$CASK" "$work/tap/$CASK" "$work/cask.sha"
cp "$work/tap/$CASK" "$work/before.rb"

current="$(sed -n -E 's/^ *version "([^"]+)".*/\1/p' "$work/before.rb" | head -1)"
say "tap      $TAP $CASK is $current"
if [ -n "$current" ] && [ "$current" != "$version" ] \
  && [ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" = "$current" ]; then
  say "the tap is already past $version; leaving it"
  exit 0
fi

# This release's manifest (by its tag, not latest/: that can lag a moment).
out="$(cd "$work/tap" && node scripts/bump.mjs \
  --manifest "https://github.com/$REPO/releases/download/$tag/copper-version.json" --out "$CASK")"
printf '%s\n' "$out" | sed 's/^/    /'
[ "$(printf '%s\n' "$out" | sed -n 's/^version=//p')" = "$version" ] || fail "the renderer did not render $version"
if [ "$(printf '%s\n' "$out" | sed -n 's/^changed=//p')" != true ]; then
  say "the cask is already $version's; nothing to commit"
  exit 0
fi
if command -v ruby > /dev/null; then
  ruby -c "$work/tap/$CASK" > /dev/null || fail "the rendered cask is not valid Ruby"
fi
diff -u "$work/before.rb" "$work/tap/$CASK" | sed 's/^/    /' || true

# One commit through the contents API, made against the sha read above.
login="$(gh api user --jq .login 2> /dev/null || true)"
# shellcheck disable=SC2016  # JavaScript, not shell
node -e '
  const fs = require("fs");
  const [cask, sha, version, tag, repo, login, out] = process.argv.slice(1);
  const body = {
    message: `copper ${version}\n\nhttps://github.com/${repo}/releases/tag/${tag}`,
    content: fs.readFileSync(cask).toString("base64"),
    sha: fs.readFileSync(sha, "utf8").trim(),
    branch: "main",
  };
  if (login === "exowatt-woodpecker-bot") {
    body.committer = { name: "exowatt-woodpecker-bot", email: "339688546+exowatt-woodpecker-bot@users.noreply.github.com" };
  }
  fs.writeFileSync(out, JSON.stringify(body));
' "$work/tap/$CASK" "$work/cask.sha" "$version" "$tag" "$REPO" "$login" "$work/put.json"
commit="$(gh api -X PUT "repos/$TAP/contents/$CASK" --input "$work/put.json" --jq .commit.sha)" \
  || fail "GitHub did not take the cask update (someone else changed it since? run again)"
say "tap      $TAP@${commit:0:12}: copper $version"
