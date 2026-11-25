#!/bin/bash
# Move in from Firefox and Zen, end to end, in a fresh headless world, from
# this Mac's own Firefox and Zen profiles. Read only: Move in copies what it
# reads, and the passwords land in the world's file keychain, never the real
# one. Needs both opened once, with some tabs, bookmarks and saved passwords
# (a throwaway profile is enough).
#
#   - both are listed as Gecko sources, readable;
#   - each one's counts, then a move through the sheet: a line per category,
#     spaces made (Zen: one per Zen space), its passwords decrypted with the
#     profile's own key4.db and in the file keychain, its sign-ins in the jar;
#   - moving again adds nothing.
#
#   docs/fixtures/flow-firefox-e2e.sh [--shots DIR] [--port N] [build/Copper.app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHOTS=""
PORT=4607
APP="$ROOT/build/Copper.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --shots) SHOTS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-firefox.XXXXXX")
WORLD="flowfirefox$(date +%s)$$"
PID=""
cleanup() {
  if [ -n "$PID" ]; then
    case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
      "$APP/Contents/MacOS/Copper"*) kill "$PID" 2>/dev/null || :; sleep 1; kill -9 "$PID" 2>/dev/null || : ;;
    esac
  fi
  defaults delete "com.collinrijock.copper.test.$WORLD" >/dev/null 2>&1 || :
  rm -rf "$HOME/Library/Application Support/Copper ($WORLD)" "$TEMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; tail -n 8 "$TEMP/app.log" >&2 || :; exit 1; }
ok() { echo "ok: $*"; }
check() { printf '%s\n' "$3" | jq -e "$2" >/dev/null || fail "$1: $3"; }
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
until_state() {
  local state
  for _ in $(seq 1 300); do
    state=$(B flow state)
    if printf '%s\n' "$state" | jq -e "$1" >/dev/null; then printf '%s\n' "$state"; return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $1: $state"
}
shot() { # the sheet as drawn, light and dark
  [ -n "$SHOTS" ] || return 0
  mkdir -p "$SHOTS"
  for look in light dark; do
    B ui look "$look" >/dev/null
    sleep 0.4
    B flow shot --path "$SHOTS/firefox-$1-$look.png" >/dev/null || fail "shot $1 $look"
  done
  B ui look light >/dev/null
}

defaults write "com.collinrijock.copper.test.$WORLD" bench -bool true
defaults write "com.collinrijock.copper.test.$WORLD" welcomed -bool true
defaults write "com.collinrijock.copper.test.$WORLD" probe.keychain -string file
open -n -g --stderr "$TEMP/app.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT="$PORT" --env SEARCH_HEADLESS_SIZE=1440x960 "$APP"
for _ in $(seq 1 120); do
  PID=$(sed -n 's/.*on — pid \([0-9][0-9]*\).*/\1/p' "$TEMP/app.log" 2>/dev/null | head -1)
  [ -n "$PID" ] && B tabs >/dev/null 2>&1 && break
  sleep 0.5
done
[ -n "$PID" ] || fail "headless probe did not start"
ok "probe $WORLD up (pid $PID, port $PORT)"

B flow limit --only Firefox,Zen >/dev/null
SOURCES=$(B flow sources)
# macOS may keep another app's folder from this build (Privacy & Security ›
# Files & Folders): then the card is locked, and a copy stands in for it.
for NAME in Firefox Zen; do
  printf '%s\n' "$SOURCES" | jq -e --arg n "$NAME" '.sources[] | select(.name == $n) | .locked' >/dev/null || continue
  FOLDER=$(printf '%s\n' "$SOURCES" | jq -r --arg n "$NAME" '.sources[] | select(.name == $n) | .root')
  ok "$NAME is locked for this build (the card says so); reading a copy of $FOLDER"
  B flow open --again >/dev/null
  until_state '.showing and .sourcesKnown' >/dev/null
  shot "$(echo "$NAME" | tr A-Z a-z)-locked"
  B flow close >/dev/null
  until_state '.showing | not' >/dev/null
  cp -R "$FOLDER" "$TEMP/$NAME"
  B flow root --source "$NAME" --path "$TEMP/$NAME" >/dev/null
  SOURCES=$(B flow sources)
done
printf '%s\n' "$SOURCES" | jq -c '.sources[] | {name, kind, glyph, readable, locked, profiles}' | sed 's/^/     /'
check "Firefox and Zen listed, readable" '[.sources[] | select(.kind == "gecko" and .readable)] | map(.name) | sort == ["Firefox", "Zen"]' "$SOURCES"
ok "Firefox and Zen are Gecko sources, readable"

for NAME in Firefox Zen; do
  SCAN=$(B flow scan --source "$NAME")
  printf '%s\n' "$SCAN" | jq -c '{source, tabs, spaces, groups, bookmarks, places, passwords}' | sed 's/^/     /'
  check "$NAME counts" '.tabs > 0 and .bookmarks > 0 and .places > 0 and .passwords > 0' "$SCAN"
  B flow open --again >/dev/null
  until_state '.showing and .sourcesKnown' >/dev/null
  B flow pick --source "$NAME" >/dev/null
  until_state ".phase == \"preview\" and .selected == \"$NAME\"" >/dev/null
  shot "$(echo "$NAME" | tr A-Z a-z)-preview"
  B flow key return >/dev/null
  until_state '.phase == "done"' >/dev/null
  shot "$(echo "$NAME" | tr A-Z a-z)-done"
  DONE=$(B flow status)
  printf '%s\n' "$DONE" | jq -r '.title, .summary[], (.stayed // [])[]' | sed 's/^/     /'
  check "$NAME move" '.spacesMade > 0 and .tabs > 0 and .bookmarks > 0 and .places > 0 and .passwords > 0 and .cookies > 0' "$DONE"
  check "$NAME: every line a tick" '[.summary[] | startswith("✓")] | all' "$DONE"
  B flow key return >/dev/null
  until_state '.showing | not' >/dev/null
  ok "$NAME: $(printf '%s\n' "$DONE" | jq -r '"\(.spacesMade) spaces, \(.tabs) tabs, \(.bookmarks) bookmarks, \(.places) places, \(.passwords) passwords, \(.cookies) cookies"')"

  AGAIN=$(B flow move --source "$NAME" --only tabs,bookmarks,history,passwords,cookies 2>/dev/null)
  check "$NAME again adds nothing" '.tabs == 0 and .spacesMade == 0 and .bookmarksNew == 0 and .placesNew == 0 and .passwordsNew == 0' "$AGAIN"
  ok "$NAME moved again: nothing new"
done

SECRETS=$(B flow secrets)
printf '%s\n' "$SECRETS" | jq -c '.passwords[]? | {host, user}' | sed 's/^/     /'
check "passwords in the world's file keychain" '.sink == "probe-file" and (.passwords | length) > 0' "$SECRETS"
B flow spaces | jq -c '.spaces[] | {name, tabs}' | sed 's/^/     /'
ok "Firefox and Zen moved in"

# The Chromium newcomers, where this Mac has them: listed and read like Chrome.
B flow limit --only Opera,Helium,Comet >/dev/null
OTHERS=$(B flow sources)
for NAME in $(printf '%s\n' "$OTHERS" | jq -r '.sources[] | select(.readable) | .name'); do
  SCAN=$(B flow scan --source "$NAME")
  printf '%s\n' "$SCAN" | jq -c '{source, tabs, bookmarks, places, passwords}' | sed 's/^/     /'
  check "$NAME read" '.source and (.notes | length) > 0' "$SCAN"
done
ok "Chromium newcomers listed: $(printf '%s\n' "$OTHERS" | jq -r '[.sources[] | "\(.name) (\(if .readable then "readable" elif .locked then "locked" else "no profile" end))"] | join(", ")')"
