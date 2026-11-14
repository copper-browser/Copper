#!/bin/bash
# Tab in a page reaches buttons and links, as in Chrome and Arc.
#
# WebKit's own default (Safari's) stops Tab at text fields unless the Mac's
# Keyboard navigation is on, so Tab from a password box never reached Sign
# in and a page's links were never reached at all. Web.configuration now sets
# WKPreferences.tabFocusesLinks.
#
#   1. Tab from the password box lands on the Sign in button.
#   2. Tab from the button lands on the link.
#   3. Tab between text fields still works.
#
# A fresh SEARCH_PROBE world, headless; no network, no real Copper world
# touched. ./build.sh first unless COPPER_SKIP_BUILD=1. (Focus rings are not
# checked: WebKit matches :focus only in a key window, and a headless one
# never is.)
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="tablinks-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
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

id="$(bench open "file://$root/docs/fixtures/tab-links.html")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
# Focus FROM, press ⇥ (to the view, then through the app), print the new focus.
tab() { bench eval "$id" "document.getElementById('$1').focus(); 1" >/dev/null; bench key "$id" "⇥" $2 >/dev/null; sleep 0.3; bench eval "$id" 'document.activeElement.id || document.activeElement.tagName'; }

for via in "" "--app"; do
  got="$(tab pass "$via")"; [ "$got" = go ] || fail "⇥ $via from the password box went to '$got', not the Sign in button"
  got="$(tab go "$via")"; [ "$got" = help ] || fail "⇥ $via from the button went to '$got', not the link"
  got="$(tab user "$via")"; [ "$got" = pass ] || fail "⇥ $via from the first field went to '$got', not the password box"
done
echo "ok Tab reaches the button and the link, and still walks the fields"
echo PASS
