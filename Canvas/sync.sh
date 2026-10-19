#!/usr/bin/env bash
# The canvas page lives in copper-browser/canvas-app. Copper vendors its embed build,
# dist/canvas.html, at the commit pinned in Canvas/CANVAS_APP_REF; build.sh copies it into the app.
#   Canvas/sync.sh                 re-fetch the pinned build (e.g. after editing CANVAS_APP_REF)
#   Canvas/sync.sh REF             pin REF (a canvas-app commit, tag or branch, resolved to a commit) and fetch it
#   Canvas/sync.sh --check         exit 1 if Canvas/dist/canvas.html is not the pinned build
#   Canvas/sync.sh --from FILE     vendor a local build (canvas-app: bun run build) — for trying changes; pin before merging
set -euo pipefail
cd "$(dirname "$0")"
repo=copper-browser/canvas-app
pin=CANVAS_APP_REF
dest=dist/canvas.html
fetch() {
  curl -fsSL "https://raw.githubusercontent.com/$repo/$1/dist/canvas.html" -o "$2"
  grep -q 'copperCanvas' "$2" || { echo "sync: $1 has no canvas page" >&2; exit 2; }
}
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
case "${1:-}" in
  --check)
    fetch "$(cat "$pin")" "$tmp"
    cmp -s "$tmp" "$dest" && echo "canvas.html matches canvas-app $(cat "$pin")" || { echo "canvas.html differs from canvas-app $(cat "$pin"): run Canvas/sync.sh" >&2; exit 1; }
    ;;
  --from)
    cp "$2" "$dest"; echo "vendored $2 (not pinned: run Canvas/sync.sh REF before merging)"
    ;;
  "")
    fetch "$(cat "$pin")" "$dest"; echo "vendored canvas-app $(cat "$pin")"
    ;;
  *)
    sha=$(gh api "repos/$repo/commits/$1" --jq .sha 2>/dev/null || git ls-remote "https://github.com/$repo.git" "$1" | cut -f1)
    [[ -n "$sha" ]] || { echo "sync: no canvas-app ref $1" >&2; exit 2; }
    fetch "$sha" "$dest"; echo "$sha" > "$pin"; echo "pinned canvas-app $sha"
    ;;
esac
