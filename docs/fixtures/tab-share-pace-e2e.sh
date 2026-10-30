#!/bin/bash
# A tab share holds its pace with Copper behind other apps (docs/screen-sharing.md › How it works, step 6).
#
# About a minute after Copper stops being the app in front — you went back to
# your notes mid-presentation, or the Mac locked — macOS slows it: its main
# thread drops to a background priority and its timers fire late, and a share
# went from 30 frames a second to 5–7 and stayed there. Copper holds a
# latency-critical activity while a share is live; this checks that it does
# its job where tab-share-e2e.sh (headless, never slowed) cannot.
#
# A windowed Copper in a fresh SEARCH_PROBE world, started in the background
# (`open -n -g`: never the active app, its window behind yours) and with
# SEARCH_MEASURE, so it is slowed as the shipped browser is (App Nap and
# WebKit's own throttling left to macOS). The pages in docs/fixtures/tab-share/
# from a local server; the picker answered by the bench.
#
#   1. Copper sits idle for COPPER_PACE_IDLE seconds (default 75) first, so
#      macOS has already slowed it when the share starts.
#   2. The share starts at pace and holds it for COPPER_PACE_SECONDS (default
#      90): two thirds with the calling tab in front and the shared one hung
#      off screen, the last third the other way round. Per second, frames the
#      share draws into its stream: median >= 25, 10th percentile >= 20, the
#      last 30 s no slower than the first; RTCPeerConnection encodes >= 20.
#   3. The control: `share pace off` for 20 s. The rate falls when macOS has
#      slowed Copper (said, not failed, when it hasn't — then step 2 proved
#      nothing, and the run says so); `on` again and it is back within seconds.
#   4. Stopping the share gives the activity back.
#
# Copper's window is on your screen, behind your own, for about four minutes.
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
world="${COPPER_SHARE_WORLD:-share-pace-$$}"
mcp="${COPPER_SHARE_MCP_PORT:-4203}"
idle="${COPPER_PACE_IDLE:-75}"
seconds="${COPPER_PACE_SECONDS:-90}"
tmp="$(mktemp -d)"
pid=""
server=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.officecommun.search.test.$world.plist"
  rm -rf "$HOME/Library/Application Support/Copper ($world)" "$tmp"
  # The world's WebKit stores (Store.probeStore: FNV-1a of the world's name).
  local hash=2166136261 i byte
  for ((i = 0; i < ${#world}; i++)); do
    printf -v byte '%d' "'${world:i:1}"
    hash=$(( ((hash ^ byte) * 16777619) & 0xFFFFFFFF ))
  done
  local stem; stem=$(printf '5E4C%04X-%04X' $((hash >> 16)) $((hash & 0xFFFF)))
  local kit="$HOME/Library/WebKit/com.collinrijock.copper.dev"
  rm -rf "$kit/WebExtensions/$stem-"* "$kit/WebsiteDataStore/$(tr 'A-F' 'a-f' <<<"$stem")-"*
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  if ! (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1; then
    fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
  fi
fi
bundle="$root/build/Copper.app"
[ -x "$bundle/Contents/MacOS/Copper" ] || fail "build: no Copper executable in $bundle"

cp -R "$root/docs/fixtures/tab-share" "$tmp/site"
port=$((20000 + $$ % 20000))
(cd "$tmp/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -sf "http://127.0.0.1:$port/pace.html" >/dev/null && break; sleep 0.25; done
web="http://localhost:$port"

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
open -n -g --env SEARCH_PROBE="$world" --env SEARCH_MCP_PORT="$mcp" --env SEARCH_MEASURE=1 \
  --stdout "$tmp/copper.log" --stderr "$tmp/copper.log" "$bundle"
launched=$(date +%s)
# `open` starts it elsewhere: this world's process, found by its executable and its environment.
for _ in {1..80}; do
  for p in $(pgrep -f "^$bundle/Contents/MacOS/Copper\$" || true); do
    ps eww -p "$p" | grep -qE "SEARCH_PROBE=$world( |\$)" && pid=$p && break
  done
  [ -n "$pid" ] && break; sleep 0.25
done
[ -n "$pid" ] || fail "Copper did not start"
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..120}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "the bench did not start (log: $(tail -1 "$tmp/copper.log"))"

open_tab() {
  bench windows open "0 $web/$1" >/dev/null
  local id=""
  for _ in {1..60}; do
    id=$(bench windows | jq -r --arg u "$web/$1" '.windows[0] as $w | [range(0; $w.tabs | length) | select($w.tabs[.] == $u)] | first as $i | if $i == null then "" else $w.tabIDs[$i] end')
    [ -n "$id" ] && break; sleep 0.25
  done
  [ -n "$id" ] || fail "no tab for $1"
  for _ in {1..60}; do [ "$(bench eval "$id" "document.readyState" 2>/dev/null)" = "complete" ] && break; sleep 0.25; done
  echo "$id"
}
# The share verbs read an all-digit id as a place in the row: hand them that place.
ref() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then bench tabs | jq -r --arg id "$1" '.tabs | map(.id) | index($id)'; else echo "$1"; fi
}
state() { bench share; }
# Per second, the last N seconds: the frames the share drew into its stream.
pace() { bench eval "$a" "JSON.stringify(window.__pace($1))"; }
stats() { # JSON array of per-second counts → median, 10th percentile
  jq -c 'sort as $s | ($s | length) as $n | { median: $s[($n / 2 | floor)], p10: $s[(($n - 1) * 0.1 | floor)], min: $s[0], n: $n }' <<<"$1"
}

b=$(open_tab b.html)
a=$(open_tab pace.html)
bench select "$a" >/dev/null
echo "tabs: caller $a, shared $b; Copper $pid, in the background (active: $(state | jq -r .appActive))"

# 1. Idle, as a Copper left behind other apps is.
wait_for=$(( idle - ($(date +%s) - launched) ))
[ "$wait_for" -gt 0 ] && sleep "$wait_for"
echo "ok idle $(( $(date +%s) - launched )) s since launch"

# 2. The share. A page behind other windows is hidden to WebKit, and getDisplayMedia wants a
# visible one: the caller ignores occlusion for the call, then notices it again (the share
# itself keeps both pages seen from then on).
bench share occlusion "$(ref "$a")" on >/dev/null
bench share answer tab "$(ref "$b")" >/dev/null
bench eval "$a" "window.__share({ video: { width: { max: 1280 }, height: { max: 720 } } })" >/dev/null
r=""
for _ in {1..80}; do r=$(bench eval "$a" "JSON.stringify(window.__result)"); [ "$(jq -r '.pending // false' <<<"$r")" != true ] && break; sleep 0.25; done
[ "$(jq -r .ok <<<"$r")" = true ] || fail "sharing the tab failed: $r"
bench share occlusion "$(ref "$a")" off >/dev/null
[ "$(state | jq -r .pace.held)" = true ] || fail "no activity held while sharing: $(state | jq -c .pace)"
echo "ok shared at $(jq -r '"\(.settings.width)x\(.settings.height)"' <<<"$r")"

front=$(( seconds * 2 / 3 ))
sleep "$front"
first=$(pace "$front")
bench select "$b" >/dev/null
sleep $(( seconds - front ))
second=$(pace $(( seconds - front )))
[ "$(state | jq -r '.shares[0].consumerHung')" = true ] || fail "the calling page was not hung while the shared tab was in front"
all=$(jq -sc '.[0].perSecond + .[1].perSecond' <<<"$first $second")
s=$(stats "$all")
early=$(stats "$(jq -c '.[:30]' <<<"$all")"); late=$(stats "$(jq -c '.[-30:]' <<<"$all")")
enc=$(jq -r .encodedFps <<<"$first")
tick=$(state | jq -c '.shares[0].timing.tickMs')
echo "   per second over ${seconds} s: $s; first 30 s $(jq -r .median <<<"$early"), last 30 s $(jq -r .median <<<"$late"); encoded $enc; tick $tick"
jq -e '.median >= 25 and .p10 >= 20' <<<"$s" >/dev/null || fail "the share did not hold its pace: $s"
jq -en --argjson e "$early" --argjson l "$late" '$l.median >= $e.median - 3' >/dev/null || fail "the share slowed over time: $early then $late"
jq -en --arg e "$enc" '($e | tonumber? // 0) >= 20' >/dev/null || fail "RTCPeerConnection encoded too few: $enc"
echo "ok the share held its pace for $seconds s, the caller and then the shared tab in front"

# 3. The control.
bench select "$a" >/dev/null
bench share pace off >/dev/null
[ "$(state | jq -r .pace.held)" = false ] || fail "pace off still holds the activity"
sleep 20
off=$(stats "$(pace 15 | jq -c .perSecond)")
bench share pace on >/dev/null
sleep 8
on=$(stats "$(pace 5 | jq -c .perSecond)")
jq -e '.median >= 25' <<<"$on" >/dev/null || fail "the pace did not come back: $on (off: $off)"
if jq -e '.median < 20' <<<"$off" >/dev/null; then
  echo "ok without the activity macOS slowed the share to $(jq -r .median <<<"$off") fps; with it, back to $(jq -r .median <<<"$on")"
else
  echo "note macOS did not slow Copper on this run (without the activity: $(jq -r .median <<<"$off") fps) — Copper in front, or the Mac busy waking it: the pace above proved nothing"
fi

# 4. The end.
bench eval "$a" "window.__stopTrack()" >/dev/null
for _ in {1..20}; do [ "$(state | jq '.shares | length')" = 0 ] && break; sleep 0.25; done
[ "$(state | jq '.shares | length')" = 0 ] || fail "the share did not end"
[ "$(state | jq -r .pace.held)" = false ] || fail "the activity outlived the share: $(state | jq -c .pace)"
echo "ok the activity ends with the share"

echo "ok tab share pace e2e"
