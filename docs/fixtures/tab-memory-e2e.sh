#!/bin/bash
# Heavy pages nobody is looking at give their memory back.
#
# November 2026: Copper held 3.4 GB five minutes after a launch with three
# pages loaded — X (a pin), the page on screen, and a Gmail that space-warm
# had loaded for a space nobody went to (980 MB, kept until memory pressure).
# Idle sleep counted pages against a budget (ten on a 16 GB Mac) whatever
# they weighed. Now a heavy page (500 MB on a 16 GB Mac) goes once it has been left the half
# hour, under the budget or not, a space's own tab included.
#
#   1. Six pages loaded: two light, three holding 600 MB (one loose, one a
#      pin, one the other space's own tab) and a light one an agent opened
#      for itself. `bench heat` weighs them.
#   2. The sweep, with seconds standing in for the half hour: the loose heavy
#      page, the other space's heavy page and the agent's page sleep; the
#      light page, the pin and the page on screen stay.
#   3. Over a gigabyte comes back, and the sleeping tabs are still in the row.
#
# A fresh SEARCH_PROBE world, headless; no network, no real Copper world
# touched. ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="tabmem-$$"
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

A=AAAAAAAA-0000-4000-8000-000000000001 B=BBBBBBBB-0000-4000-8000-000000000002
page="file://$root/docs/fixtures/heavy.html"
mkdir -p "$folder"
cat >"$folder/session.json" <<JSON
{"active":1,"space":"$A",
 "spaces":[{"id":"$A","name":"Alpha","hue":0.1},{"id":"$B","name":"Beta","hue":0.6}],
 "pins":[{"url":"$page?name=pin&mb=600","title":"pin","space":"$A","pin":"P"}],
 "tabs":[
  {"url":"$page?name=pin&mb=600","title":"pin","space":"$A","pin":"P"},
  {"url":"$page?name=front","title":"front","space":"$A","saved":true},
  {"url":"$page?name=light","title":"light","space":"$A","saved":true},
  {"url":"$page?name=heavy&mb=600","title":"heavy","space":"$A","saved":true},
  {"url":"$page?name=other&mb=600","title":"other","space":"$B","saved":true}]}
JSON
defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
defaults write "$domain" spaces.warm -bool false
defaults write "$domain" agents.linger -int 2    # an agent lets go of its tab in seconds, not five minutes
port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")
token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
printf '{"enabled":true,"port":%s,"token":"%s","announces":false,"jev":false}' "$port" "$token" >"$folder/agent.json"
mcp() { curl -s -m 20 -X POST "http://127.0.0.1:$port/mcp" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
defaults write "$domain" sleep.heavy -int 500   # a 16 GB Mac's; the line rises with memory
bench() { "$root/bench" --world "$world" "$@"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

# The id of the tab titled $1, in the space on screen.
id() { bench tabs | grep -E " (\[.\] )?$1  " | grep -oE '[0-9a-f]{8}' | head -1; }
load() { local tab; tab="$(id "$1")"; [ -n "$tab" ] || fail "no tab $1"; bench select "$tab" >/dev/null; bench wait "$tab" 20 >/dev/null; }
# Whether the page titled $1 is loaded, in any space: `heat` lists those.
loaded() { bench heat | grep -q "  $1\$"; }
# Megabytes in loaded pages: the last line of `heat`.
total() { bench heat | tail -1 | awk '{print $1}'; }

# 1. Every page loaded; the other space's is its own (remembered) tab.
bench spaces select 1 >/dev/null; load other
bench spaces select 0 >/dev/null; load pin; load heavy; load light; load front
mcp browser_tabs "{\"action\":\"new\",\"url\":\"$page?name=agent\"}" | grep -q '"isError":false' || fail "the agent could not open a tab"
sleep 2
before="$(total)"
loaded agent || fail "the agent's page is not loaded"
[ "$(bench heat | awk '/ pid / && $1 >= 600' | wc -l | tr -d ' ')" = 3 ] || fail "expected three pages over 600 MB: $(bench heat | tr '\n' ';')"
echo "ok 1 six pages loaded, $before MB, three of them heavy"

# 2. The sweep, three seconds standing in for the half hour.
sleep 3
bench sleep sweep 3 >"$tmp/sweep.json"
sleep 3
loaded heavy && fail "the heavy page left alone is still loaded ($(tr -d '\n ' <"$tmp/sweep.json"))"
loaded other && fail "the other space's heavy page is still loaded"
loaded agent && fail "the page an agent opened and left is still loaded"
loaded light || fail "the light page under the budget was put to sleep"
loaded pin || fail "a pin was put to sleep"
loaded front || fail "the page on screen was put to sleep"
echo "ok 2 the two heavy pages and the agent's page sleep; the light page, the pin and the page on screen stay"

# 3. What came back, and the tab is still there to click.
after="$(total)"
[ $((before - after)) -ge 1100 ] || fail "only $((before - after)) MB came back ($before → $after)"
bench tabs | grep -q " heavy  .* z\$" || fail "the sleeping tab is not in the row, asleep"
echo "ok 3 $before MB → $after MB with the same tabs in the row"
echo PASS
