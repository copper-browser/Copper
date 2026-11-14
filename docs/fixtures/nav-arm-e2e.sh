#!/bin/bash
# What a page is armed with at each navigation, in one tab going between
# sites — the ad blocker, the hidden elements (veils) and the sign-in watcher
# in the page and in its frame. Since a tab re-arms only when what it would
# put down changes (Tab.arm, Shield.tune), this checks every page still gets
# the right set: nav-arm.html served from 127.0.0.1 and from localhost, in a
# probe world where the blocker is paused on localhost and #veiled is hidden
# on 127.0.0.1.
#
#   127.0.0.1 → localhost → 127.0.0.1 → 127.0.0.1 (same set, nothing re-armed)
#   ad:       hidden    shown       hidden      hidden
#   #veiled:  hidden    shown       hidden      hidden
#   watcher:  page + frame on every one
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="navarm-$$"
port="${FIXTURE_PORT:-$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")}"
tmp="$(mktemp -d)"
pid="" server=""
folder="$HOME/Library/Application Support/Copper ($world)"
cleanup() {
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  [ -n "$server" ] && { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
  defaults delete "com.collinrijock.copper.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.collinrijock.copper.test.$world.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

(cd "$root/docs/fixtures" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/http.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -fsS -o /dev/null 2>/dev/null "http://127.0.0.1:$port/nav-arm.html" && break; sleep 0.25; done
defaults write "com.collinrijock.copper.test.$world" bench -bool true
defaults write "com.collinrijock.copper.test.$world" welcomed -bool true
defaults write "com.collinrijock.copper.test.$world" shield.paused -array localhost
mkdir -p "$folder"
echo '{"127.0.0.1":[{"selector":"#veiled","label":"fixture","date":0}]}' >"$folder/hidden.json"
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
sleep 2 # the blocker's list compiles at launch

tab=$(bench open "http://127.0.0.1:$port/nav-arm.html" | grep -oE '[0-9a-f]{8}' | head -1)
[ -n "$tab" ] || fail "no tab"

# check URL AT WANT: load URL in the same tab (the first is already loading), read the page's report.
check() {
  local url=$1 want="{\"at\":\"$2\",$3" got=""
  [ "$url" = first ] || bench go "$tab" "$url" >/dev/null
  bench wait "$tab" 10 >/dev/null
  for _ in {1..20}; do
    got=$(bench eval "$tab" 'window.report ? window.report() : ""' 2>/dev/null || true)
    [ "$got" = "$want" ] && { echo "ok   $got"; return; }
    sleep 0.25
  done
  fail "$url: got $got, want $want"
}
armed='"ad":"none","veiled":"none","forms":true,"frameForms":true}'
bare='"ad":"inline","veiled":"block","forms":true,"frameForms":true}'
check first 127.0.0.1 "$armed"
check "http://localhost:$port/nav-arm.html" localhost "$bare"
check "http://127.0.0.1:$port/nav-arm.html?again" "127.0.0.1?again" "$armed"
check "http://127.0.0.1:$port/nav-arm.html?same" "127.0.0.1?same" "$armed"
echo "PASS nav-arm"
