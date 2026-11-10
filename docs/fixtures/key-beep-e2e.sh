#!/bin/bash
# Keys a page used never beep.
#
# November 2026: ← and → on X and YouTube worked in the page and macOS still
# played its "can't do that" sound. WebKit hands a key the page didn't cancel
# back up the responder chain; PageView.keyDown keeps that return trip quiet,
# but it remembered one key, and the page answers a moment later — so a held
# arrow or quick taps put the next key in first and every return was missed.
#
#   1. One key, then bursts (arrows, j k l), on a busy page that uses its keys
#      without preventDefault, to the view and through the app's key monitor:
#      every key sent back is kept quiet.
#   2. Typing still lands in a page's text field.
#   3. ⌘L still opens the address field, and typing lands in it, not the page.
#
# A fresh SEARCH_PROBE world, headless; no network, no real Copper world
# touched. ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="keybeep-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.officecommun.search.test.$world"
tmp="$(mktemp -d)"
pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
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

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

id="$(bench open "file://$root/docs/fixtures/keys.html#busy")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
# "SENT QUIETED" for keys pressed on the page.
press() { bench key "$id" "$@" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sentBackUnused"], d["quieted"])'; }

# 1. Every key the page hands back is kept quiet.
for keys in "→" "←→←→" "jkl" "→→→→→→→→→→→→"; do
  for via in "" "--app"; do
    read -r sent quiet <<<"$(press "$keys" $via)"
    [ "$sent" = "${#keys}" ] || fail "'$keys' $via: the page sent back $sent of ${#keys} (the fixture should hand back every key)"
    [ "$quiet" = "$sent" ] || fail "'$keys' $via: $((sent - quiet)) of $sent keys would beep"
  done
done
[ "$(bench eval "$id" 'used.length')" = 40 ] || fail "the page saw $(bench eval "$id" 'used.length') keys, not 40"
echo "ok 1 keys the page used are quiet, one at a time and in bursts"

# 2. A page's text field.
bench eval "$id" 'document.getElementById("box").focus(); 1' >/dev/null
press "hello" >/dev/null
[ "$(bench eval "$id" 'document.getElementById("box").value')" = hello ] || fail "typing did not reach the page's field"
echo "ok 2 typing reaches a page's text field"

# 3. The app's shortcut, and its own field.
press "⌘l" --app >/dev/null
bench probe | grep -q '"field": true' || fail "⌘L did not open the address field"
press "abc" --app >/dev/null
bench probe | grep -q '"typed": "abc"' || fail "typing did not reach the address field"
[ "$(bench eval "$id" 'document.getElementById("box").value')" = hello ] || fail "address-field typing leaked into the page"
echo "ok 3 ⌘L opens the address field and typing lands there"
echo PASS
