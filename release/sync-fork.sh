#!/usr/bin/env bash
# Roadrunner's sync-fork (.woodpecker/sync-fork.yaml, on the Mac): when main moved, rebase fork
# onto it, build, push sync/<date> and open a PR to fork. Needs GH_TOKEN; host tools git, swift, gh.
set -euo pipefail
: "${GH_TOKEN:?GH_TOKEN must be set}"
cd "$(dirname "$0")/.."
repo=copper-browser/Copper
# shellcheck disable=SC2016 # $GH_TOKEN is expanded by the helper, not here.
git config credential.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
export GIT_TERMINAL_PROMPT=0
git config user.name copper-sync && git config user.email copper-sync@users.noreply.github.com
git fetch -q "https://github.com/$repo.git" +refs/heads/main:refs/remotes/origin/main +refs/heads/fork:refs/remotes/origin/fork
if git rev-parse --is-shallow-repository | grep -q true; then git fetch -q --unshallow "https://github.com/$repo.git"; fi
git checkout -q -B fork origin/fork
if git merge-base --is-ancestor origin/main fork; then echo "fork already on main"; exit 0; fi
git checkout -q -b "sync/$(date +%F)" fork
git rebase origin/main || { echo "rebase conflict — see PATCHES.md" >&2; git rebase --abort || true; exit 1; }
swift build
git push "https://github.com/$repo.git" HEAD
gh pr create -R "$repo" --base fork --head "sync/$(date +%F)" --title "Sync upstream $(date +%F)" \
  --body "$(git range-diff origin/fork...HEAD | head -200)"
