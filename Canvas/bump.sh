#!/usr/bin/env bash
# Roadrunner's hourly canvas bump (.woodpecker/canvas.yaml): when canvas-app main's page differs
# from the pinned one, push branch canvas/take-canvas-app pinning it and open or update one issue
# with its commit list and a link that opens the PR; close the issue once the pin has caught up.
# Needs GH_TOKEN (push + issues on this repo). Host tools: bash, git, curl, jq.
set -euo pipefail
: "${GH_TOKEN:?GH_TOKEN must be set}"
cd "$(dirname "$0")/.."
repo=copper-browser/Copper
title="Canvas: canvas-app moved on"
branch=canvas/take-canvas-app
api() { # api METHOD PATH [JSON]
  curl -fsS --retry 3 --max-time 60 -X "$1" -H "Authorization: Bearer $GH_TOKEN" \
    -H 'Accept: application/vnd.github+json' "https://api.github.com/$2" ${3:+--data "$3"}
}
open_issues() {
  api GET "search/issues?q=$(jq -rn --arg q "repo:$repo is:issue is:open in:title \"$title\"" '$q|@uri')" |
    jq -r --arg t "$title" '.items[] | select(.title == $t) | .number'
}

old=$(cat Canvas/CANVAS_APP_REF)
Canvas/sync.sh main
new=$(cat Canvas/CANVAS_APP_REF)
# Only the page counts: a canvas-app commit that leaves dist/canvas.html as it was keeps the pin.
if git diff --quiet -- Canvas/dist/canvas.html; then
  git checkout -- Canvas/CANVAS_APP_REF
  for num in $(open_issues); do
    body=$(jq -n --arg b "Copper's page is canvas-app main's (pinned ${old:0:7})." '{body: $b}')
    api POST "repos/$repo/issues/$num/comments" "$body" >/dev/null
    api PATCH "repos/$repo/issues/$num" '{"state":"closed"}' >/dev/null
    echo "closed #$num"
  done
  echo "pin is current (${old:0:7})"
  exit 0
fi

git config user.name exowatt-woodpecker-bot
git config user.email 339688546+exowatt-woodpecker-bot@users.noreply.github.com
git checkout -q -B "$branch"
git commit -qam "Canvas: take canvas-app ${new:0:7}" -m "https://github.com/copper-browser/canvas-app/compare/${old:0:12}...${new:0:12}"
# The token reaches git through a credential helper (never the command line or the remote URL).
# shellcheck disable=SC2016 # $GH_TOKEN is expanded by the helper, not here.
GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
  -c credential.helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' \
  push -f "https://github.com/$repo.git" "HEAD:refs/heads/$branch"

log=$(api GET "repos/copper-browser/canvas-app/compare/$old...$new" |
  jq -r '.commits[] | "- " + (.commit.message | split("\n")[0]) + " (" + .sha[0:7] + ")"' | head -50)
# shellcheck disable=SC2016 # literal backticks (Markdown).
body=$(printf 'canvas-app `main` is at %s; Copper pins %s. Branch `%s` pins it and vendors its `dist/canvas.html` (`Canvas/sync.sh`).\n\n**[Open the pull request](https://github.com/%s/compare/fork...%s?expand=1)**\n\n%s\n\nhttps://github.com/copper-browser/canvas-app/compare/%s...%s\n\nThis issue is updated every hour while the pin is behind; it closes when the pin catches up.\n' \
  "${new:0:7}" "${old:0:7}" "$branch" "$repo" "$branch" "$log" "${old:0:12}" "${new:0:12}")
num=$(open_issues | head -1)
if [ -n "$num" ]; then
  api PATCH "repos/$repo/issues/$num" "$(jq -n --arg b "$body" '{body: $b}')" >/dev/null
  echo "updated #$num"
else
  api POST "repos/$repo/issues" "$(jq -n --arg t "$title" --arg b "$body" '{title: $t, body: $b}')" | jq -r '"opened #\(.number)"'
fi
