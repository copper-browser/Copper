#!/bin/bash
# Little Copper, Peek and Air Traffic Control, end to end.
#
#   1. A rule (any app, localhost → Little Copper) takes a link sent the way
#      another app sends one — `open -a` this Copper, an Apple Event through
#      LaunchServices — into a Little Copper window; `atc last` names rule 1.
#   2. Open in Copper moves that page, as it is, into the window as the
#      active tab.
#   3. A link no rule names lands as a tab in the window, as before.
#   4. ⇧-click on a link (a real click event with ⇧) peeks over the page; ⌘↩
#      keeps it as a tab; a second peek put away with ⎋ leaves no tab.
#   5. A rule naming another app doesn't take a link from this one.
#
# A fresh SEARCH_PROBE world, headless, that keeps links for itself
# (COPPER_MAIN_WORLD names it); a local page server, no network. The real
# Copper is never touched. ./build.sh first unless COPPER_SKIP_BUILD=1;
# SHOTS=DIR keeps pictures of Little Copper, Peek and Settings there.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="atc-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
tmp="$(mktemp -d)"
pid="" server=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
trap 'echo "FAIL line $LINENO: $BASH_COMMAND"' ERR
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
bundle="${COPPER_APP:-$root/build/Copper.app}"
app="$bundle/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

# The pages: one with a link on its own site and one to another (127.0.0.1), the link's page.
web_port="${ATC_WEB_PORT:-$((20000 + $$ % 20000))}"
mkdir -p "$tmp/site"
cat >"$tmp/site/one.html" <<HTML
<!doctype html><title>One</title><body style="font:16px -apple-system;padding:40px">
<h1>One</h1><p><a id="two" href="/two.html" style="font-size:24px">A link to page two</a></p>
<p><a id="away" href="http://127.0.0.1:$web_port/two.html" style="font-size:24px">The same page on another site</a></p></body>
HTML
cat >"$tmp/site/two.html" <<'HTML'
<!doctype html><title>Two</title><body style="font:16px -apple-system;padding:40px;background:#fff7ef">
<h1>Page two</h1><p>Opened from somewhere else.</p></body>
HTML
(cd "$tmp/site" && exec python3 -m http.server "$web_port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
site="http://localhost:$web_port"

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
COPPER_MAIN_WORLD="$world" SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4604}" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
curl -fsS "$site/one.html" >/dev/null || fail "page server did not start"
# `open -a` must reach this process. Should LaunchServices start a second
# copy of this build instead, it is ours: found here, and stopped.
strays() { pgrep -f "^$app" | grep -vx "$pid" || true; }
send() {
  open -g -a "$bundle" "$1"
  sleep 0.5
  for stray in $(strays); do kill "$stray" 2>/dev/null || true; echo "note: open -a started a second Copper ($stray), stopped"; done
}

# 1. A rule sends a link from outside to Little Copper.
bench atc add site=localhost/two.html open=little >/dev/null
send "$site/two.html"
for _ in {1..40}; do [ "$(bench little | json 'len(d["littles"])')" -ge 1 ] && break; sleep 0.25; done
littles="$(bench little)"
[ "$(echo "$littles" | json 'len(d["littles"])')" = 1 ] || fail "no Little Copper after open -a: $littles; atc last: $(bench atc last)"
from="$(bench atc last | json 'd.get("rule")')"
[ "$from" = 0 ] || fail "atc last says rule '$from', not rule 1: $(bench atc last)"
for _ in {1..40}; do [ "$(bench little | json 'd["littles"][0]["title"]')" = "Two" ] && break; sleep 0.25; done
echo "$littles" | grep -q "two.html" || fail "Little Copper is not on two.html: $littles"
echo "ok open -a $site/two.html → rule 1 → Little Copper ($(bench atc last | json 'd["from"] or "no app"'))"
if [ -n "${SHOTS:-}" ]; then sleep 1; bench little shot 0 "$SHOTS/little-copper.png" >/dev/null; fi

# 2. Open in Copper: into the window, active, same page.
tabs_before="$(bench windows | json 'len(d["windows"][0]["tabs"])')"
bench little copper >/dev/null
sleep 0.5
[ "$(bench little | json 'len(d["littles"])')" = 0 ] || fail "Little Copper still open after Open in Copper"
win="$(bench windows)"
[ "$(echo "$win" | json 'len(d["windows"][0]["tabs"])')" = $((tabs_before + 1)) ] || fail "Open in Copper did not add a tab: $win"
[ "$(echo "$win" | json 'd["windows"][0]["tabs"][d["windows"][0]["active"]]')" = "$site/two.html" ] || fail "the active tab is not two.html: $win"
echo "ok Open in Copper → the active tab, same page"

# 3. A link no rule names lands as a tab, as before.
send "$site/one.html"
for _ in {1..40}; do bench windows | grep -q "one.html" && break; sleep 0.25; done
win="$(bench windows)"
[ "$(echo "$win" | json 'd["windows"][0]["tabs"][d["windows"][0]["active"]]')" = "$site/one.html" ] || fail "one.html did not land as the active tab: $win"
[ "$(bench atc last | json 'd.get("rule")')" = -1 ] || fail "atc last: $(bench atc last)"
[ "$(bench little | json 'len(d["littles"])')" = 0 ] || fail "a Little Copper opened for a link no rule names"
echo "ok a link no rule names → a tab in front (everything else)"

# 4. ⇧-click peeks; ⌘↩ keeps it; ⎋ puts the next one away.
id="$(bench windows | json '[i for i, u in zip(d["windows"][0]["tabIDs"], d["windows"][0]["tabs"]) if u.endswith("one.html")][0]')"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
tabs_before="$(bench windows | json 'len(d["windows"][0]["tabs"])')"
bench peek click "#two" >/dev/null
for _ in {1..40}; do [ "$(bench peek | json 'd["showing"]')" = True ] && break; sleep 0.25; done
peek="$(bench peek)"
[ "$(echo "$peek" | json 'd["showing"]')" = True ] || fail "⇧-click did not peek: $peek"
[ "$(echo "$peek" | json 'd["active"]')" = "$site/one.html" ] || fail "the page under the peek moved: $peek"
[ "$(echo "$peek" | json 'd["tabs"]')" = "$tabs_before" ] || fail "a peek added a tab: $peek"
echo "ok ⇧-click → Peek over one.html, no new tab"
if [ -n "${SHOTS:-}" ]; then sleep 1.2; bench window "$SHOTS/peek.png" >/dev/null; fi
bench peek key "⌘↩" >/dev/null
sleep 0.4
peek="$(bench peek)"
[ "$(echo "$peek" | json 'd["showing"]')" = False ] || fail "⌘↩ left the peek up: $peek"
[ "$(echo "$peek" | json 'd["tabs"]')" = $((tabs_before + 1)) ] || fail "⌘↩ did not keep it as a tab: $peek"
[ "$(echo "$peek" | json 'd["active"]')" = "$site/two.html" ] || fail "⌘↩ did not go to the kept tab: $peek"
echo "ok ⌘↩ → kept as the active tab"
bench select "$id" >/dev/null
bench peek click "#two" >/dev/null
for _ in {1..40}; do [ "$(bench peek | json 'd["showing"]')" = True ] && break; sleep 0.25; done
bench peek key "⎋" >/dev/null
sleep 0.4
peek="$(bench peek)"
[ "$(echo "$peek" | json 'd["showing"]')" = False ] || fail "⎋ left the peek up: $peek"
[ "$(echo "$peek" | json 'd["tabs"]')" = $((tabs_before + 1)) ] || fail "⎋ kept a tab: $peek"
echo "ok ⎋ → put away, no tab left"

# 4b. Opted in, a pin's plain click to another site peeks.
bench pin "$id" O >/dev/null
bench peek pins on >/dev/null
bench select "$id" >/dev/null
bench peek click "#away plain" >/dev/null
for _ in {1..40}; do [ "$(bench peek | json 'd["showing"]')" = True ] && break; sleep 0.25; done
peek="$(bench peek)"
[ "$(echo "$peek" | json 'd["showing"]')" = True ] || fail "a pin's link to another site did not peek: $peek"
echo "$peek" | grep -q "127.0.0.1" || fail "the peek is not the other site's page: $peek"
bench peek key "⎋" >/dev/null
bench peek pins off >/dev/null
bench unpin "$id" >/dev/null
echo "ok a pin's link to another site → Peek (opted in)"

# 5. A rule for another app leaves this link alone.
bench atc clear >/dev/null
bench atc add site=localhost app=com.tinyspeck.slackmacgap open=little >/dev/null
[ "$(bench atc try "$site/two.html" com.tinyspeck.slackmacgap | json 'd["open"]')" = little ] || fail "the Slack rule doesn't take Slack's link"
[ "$(bench atc try "$site/two.html" com.apple.Terminal | json 'd["open"]')" = tab ] || fail "the Slack rule took Terminal's link"
bench atc route "$site/two.html" com.apple.Terminal >/dev/null
sleep 0.3
[ "$(bench little | json 'len(d["littles"])')" = 0 ] || fail "a Slack-only rule opened a Little Copper for Terminal"
echo "ok a rule for Slack leaves a link from Terminal alone"

# Settings search lands on every new row, and each row it names is drawn.
check="$(bench settings index check)"
[ "$(echo "$check" | json 'd["ok"]')" = True ] || fail "settings index check: $check"
echo "ok settings index check"

if [ -n "${SHOTS:-}" ]; then
  # The real thing, for the pictures: a GitHub link from outside, to Little Copper.
  bench atc add site=github.com open=little >/dev/null
  bench atc else open=tab >/dev/null
  send "https://github.com/copper-browser/Copper"
  for _ in {1..60}; do [ "$(bench little | json 'len(d["littles"]) > 0 and d["littles"][-1]["title"] != ""')" = True ] && break; sleep 0.5; done
  sleep 2
  echo "shot: $(bench little | json 'd["littles"][-1]["url"]') ← $(bench atc last)"
  bench little shot 0 "$SHOTS/little-github.png" >/dev/null || true
  bench little close >/dev/null || true
  bench settings open general >/dev/null
  bench settings search "air traffic" >/dev/null
  bench settings pick 1 >/dev/null
  sleep 1.2
  bench window "$SHOTS/settings-atc.png" >/dev/null
  bench settings close >/dev/null || true
fi
echo PASS
