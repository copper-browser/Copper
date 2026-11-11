#!/bin/bash
# Folders survive a second window.
#
# November 2026: on a Mac with two windows open, every Saved tab of a space
# came out of its folder (the other Mac and the PC still had them filed, and
# the cloud's brake kept the document right). GroupsUI pruned folder
# membership against `browser.tabs + Spaces.parkedTabs`; `parkedTabs` leaves
# out `Spaces.current` (the front window's space), so whenever another
# window's row changed — a space switch there, a tab opened or closed —
# every tab of the front window's space lost its folder. Now it prunes against every tab (`Spaces.everyTab`).
#
#   1. Two spaces, each with Saved tabs in a folder; window 0 shows A, a ⌘N
#      window goes to B (this alone flattened A), and a tab opened and closed
#      in window 1 (B) leaves A's tabs in their folder.
#   2. …and the same from window 0 for B's tabs.
#   3. ⌘Q writes every tab still filed; a relaunch reads them back filed.
#
# A fresh SEARCH_PROBE world, headless; no network, no real Copper world
# touched. ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="folderwin-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
tmp="$(mktemp -d)"
pid=""
stop() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$pid" 2>/dev/null || true
    pid=""
  fi
}
cleanup() {
  stop
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

# Two spaces; two Saved tabs each, in that space's folder. Asleep at launch,
# so nothing loads.
A=AAAAAAAA-0000-4000-8000-000000000001 B=BBBBBBBB-0000-4000-8000-000000000002
FA=AAAAAAAA-0000-4000-8000-0000000000FA FB=BBBBBBBB-0000-4000-8000-0000000000FB
mkdir -p "$folder"
cat >"$folder/groups.json" <<JSON
{"groups":[{"id":"$FA","name":"Folder A","hue":0.1,"collapsed":false,"space":"$A"},
           {"id":"$FB","name":"Folder B","hue":0.6,"collapsed":false,"space":"$B"}]}
JSON
cat >"$folder/session.json" <<JSON
{"active":0,"space":"$A","pins":[],
 "spaces":[{"id":"$A","name":"Alpha","hue":0.1},{"id":"$B","name":"Beta","hue":0.6}],
 "tabs":[
  {"url":"http://127.0.0.1:9/a1","title":"a1","space":"$A","saved":true,"group":"$FA"},
  {"url":"http://127.0.0.1:9/a2","title":"a2","space":"$A","saved":true,"group":"$FA"},
  {"url":"http://127.0.0.1:9/b1","title":"b1","space":"$B","saved":true,"group":"$FB"},
  {"url":"http://127.0.0.1:9/b2","title":"b2","space":"$B","saved":true,"group":"$FB"}]}
JSON

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
# The sidebar, where folders are drawn (a fresh world has its tabs on top).
defaults write "$domain" sidebar -bool true
bench() { "$root/bench" --world "$world" "$@"; }
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return 0; sleep 0.5; done
  fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
# How many of a folder's tabs the app holds filed, across every window.
filed() { bench groups | jq --arg n "$1" '[.groups[] | select(.name == $n) | .tabs[]] | length'; }
# The tabs the session file has in a folder.
written() { jq --arg g "$1" '[.tabs[] | select(.group == $g)] | length' "$folder/session.json"; }
# A tab opened and closed in window N: the row changes there, and only there.
churn() {
  bench windows open "$1" "http://127.0.0.1:9/churn-$1" >/dev/null
  sleep 1
  local id
  id=$(bench windows | jq -r --argjson n "$1" '.windows[$n].tabIDs[-1]')
  bench windows closetab "$1" "$id" >/dev/null
  sleep 1
}

launch
[ "$(filed "Folder A")" = 2 ] && [ "$(filed "Folder B")" = 2 ] || fail "seeded folders did not restore ($(bench groups | jq -c .))"
bench windows new >/dev/null
for _ in {1..20}; do [ "$(bench windows | jq '.windows | length')" = 2 ] && break; sleep 0.25; done
[ "$(bench windows | jq '.windows | length')" = 2 ] || fail "no second window"
bench windows space 1 1 >/dev/null
sleep 1
[ "$(bench windows | jq -r '.windows[1].spaceName')" = Beta ] || fail "window 1 is not on Beta"
[ "$(bench windows | jq -r '.windows[0].spaceName')" = Alpha ] || fail "window 0 is not on Alpha"
# The switch alone redraws window 1's column: what flattened Alpha before.
[ "$(filed "Folder A")" = 2 ] || fail "window 1 going to Beta took Alpha's tabs out of Folder A ($(filed "Folder A") left)"
echo "ok two windows, Alpha and Beta, and Folder A still whole"

# 1. The main window's space while the other window's row changes.
churn 1
[ "$(filed "Folder A")" = 2 ] || fail "a tab opened in window 1 took Alpha's tabs out of Folder A ($(filed "Folder A") left)"
[ "$(filed "Folder B")" = 2 ] || fail "Folder B lost tabs after window 1's churn"
echo "ok a tab opened and closed in window 1 leaves window 0's folder whole"

# 2. The other way round.
bench windows key 1 >/dev/null
sleep 0.5
churn 0
[ "$(filed "Folder B")" = 2 ] || fail "a tab opened in window 0 took Beta's tabs out of Folder B ($(filed "Folder B") left)"
[ "$(filed "Folder A")" = 2 ] || fail "Folder A lost tabs after window 0's churn"
echo "ok a tab opened and closed in window 0 leaves window 1's folder whole"

# 3. Written, and read back.
bench windows quit >/dev/null
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
pid=""
[ "$(written "$FA")" = 2 ] && [ "$(written "$FB")" = 2 ] || fail "session.json lost folders (A $(written "$FA"), B $(written "$FB"))"
launch
[ "$(filed "Folder A")" = 2 ] && [ "$(filed "Folder B")" = 2 ] || fail "relaunch lost folders ($(bench groups | jq -c .))"
echo "ok ⌘Q writes them filed and a relaunch reads them back filed"
echo "PASS folders-windows-e2e"
