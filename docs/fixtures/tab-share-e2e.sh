#!/bin/bash
# Sharing one tab with getDisplayMedia (docs/screen-sharing.md), end to end:
# a headless Copper in a fresh SEARCH_PROBE world, the pages in
# docs/fixtures/tab-share/ from a local server, the share picker answered by
# the bench (a test world's hook), WebKit's mock capture devices for the
# window and screen answers (SEARCH_SHARE_MOCK=1). No network, no real
# Copper world touched, nothing on screen.
#
#   1. The wrapper is invisible to feature detection until called.
#   2. getDisplayMedia puts up Copper's picker: the other tabs, a window, the
#      screen — never the calling tab — and Copper answers WebKit's private
#      display-capture question.
#   3. A tab: a live track (displaySurface "browser", the tab's title), at
#      15 fps or better, every frame different, at most 1920 wide; Copper
#      holds its latency-critical activity while it lasts (the pace over
#      time, behind other apps: tab-share-pace-e2e.sh).
#   4. It keeps coming with the calling tab in front and the shared one
#      behind (the shared tab hung where it paints), and over RTCPeerConnection.
#   5. With the shared tab in front, the calling page keeps its pace too.
#   6. The page's track.stop() ends Copper's capture and its activity;
#      closing the shared tab ends the track ('ended'); Copper's Stop does too.
#   7. Cancel is NotAllowedError; "A window…" and "Entire screen…" reach
#      WebKit's own path (WindowPrompt / ScreenPrompt → the mock devices).
#   8. A cross-origin iframe with allow="display-capture" can share a tab.
#   9. The page's constraints shrink the picture.
#  10. Nothing without a pick: a page posting to Copper's handler itself gets
#      no picture of any tab, not with a made-up share id, not with another
#      page's or another frame's real one, not from the next document in the
#      same tab; an ask planted by another origin's frame is never handed a
#      frame's request; and a page that leaves ends its share at once, even
#      with its pagehide silenced.
#
# Pictures of the picker and the bar land in $COPPER_SHARE_SHOTS
# (default /tmp/copper-tabshare-qa). ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="${COPPER_SHARE_WORLD:-share-e2e-$$}"
mcp="${COPPER_SHARE_MCP_PORT:-4202}"
shots="${COPPER_SHARE_SHOTS:-/tmp/copper-tabshare-qa}"
tmp="$(mktemp -d)"
pid=""
server=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
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
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build: no Copper executable at $app"
mkdir -p "$shots"

# The pages, and a clip for the video check when ffmpeg is about.
cp -R "$root/docs/fixtures/tab-share" "$tmp/site"
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30" -t 20 -c:v libx264 -pix_fmt yuv420p \
    -movflags +faststart "$tmp/site/clip.mp4" || true
fi
port=$((20000 + $$ % 20000))
(cd "$tmp/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -sf "http://127.0.0.1:$port/a.html" >/dev/null && break; sleep 0.25; done
web="http://localhost:$port"

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
SEARCH_PROBE="$world" SEARCH_MCP_PORT="$mcp" SEARCH_HEADLESS=1 SEARCH_SHARE_MOCK=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

# Tab ids, by the page each was opened on.
open_tab() {
  bench windows open "0 $web/$1" >/dev/null
  local id=""
  for _ in {1..40}; do
    id=$(bench windows | jq -r --arg u "$web/$1" '.windows[0] as $w | [range(0; $w.tabs | length) | select($w.tabs[.] == $u)] | first as $i | if $i == null then "" else $w.tabIDs[$i] end')
    [ -n "$id" ] && break; sleep 0.25
  done
  [ -n "$id" ] || fail "no tab for $1"
  for _ in {1..40}; do [ "$(bench eval "$id" "document.readyState" 2>/dev/null)" = "complete" ] && break; sleep 0.25; done
  echo "$id"
}
# A page's promise, awaited: its JSON lands in window.__out.
await() {
  local tab=$1 expr=$2 wait=${3:-10} v=""
  bench eval "$tab" "window.__out = null; Promise.resolve($expr).then(v => window.__out = JSON.stringify(v), e => window.__out = JSON.stringify({ error: String(e) })); 'ok'" >/dev/null
  for _ in $(seq 1 $((wait * 4 + 40))); do
    v=$(bench eval "$tab" "window.__out || ''")
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 0.25
  done
  fail "no answer from $expr"
}
state() { bench share; }
result() { bench eval "$a" "JSON.stringify(window.__result)"; }
share() { # share OPTIONS — the call, then the page's answer
  bench eval "$a" "window.__share($1); 'started'" >/dev/null
  local r=""
  for _ in {1..40}; do
    r=$(result); [ "$r" != "null" ] && [ "$(jq -r '.pending // false' <<<"$r")" != true ] && break; sleep 0.25
  done
  echo "$r"
}

b=$(open_tab b.html)
c=$(open_tab c.html)
a=$(open_tab a.html)
echo "tabs: caller $a, shared $b, media $c"

# 1. Feature detection.
detect=$(bench eval "$a" "JSON.stringify(window.__detect())")
[ "$(jq -r .name <<<"$detect")" = getDisplayMedia ] || fail "the wrapper changed the function's name: $detect"
jq -e '.toString | contains("[native code]")' <<<"$detect" >/dev/null || fail "the wrapper shows its source: $detect"
[ "$(jq -r .own <<<"$detect")" = false ] || fail "the wrapper sits on the instance, not the prototype"
[ "$(jq -r .supported.displaySurface <<<"$detect")" = true ] || fail "getSupportedConstraints lost displaySurface"
[ "$(jq '.decisions | length' <<<"$(state)")" = 0 ] || fail "Copper heard from a page that never asked"
echo "ok the wrapper looks like WebKit's own until it is called"

# 2. The picker.
bench eval "$a" "window.__share({ video: true, audio: true }); 'started'" >/dev/null
rows=""
for _ in {1..40}; do rows=$(state | jq -c '.picker.rows // empty'); [ -n "$rows" ] && break; sleep 0.25; done
[ -n "$rows" ] || fail "no picker came up: $(state | jq -c .decisions)"
jq -e --arg b "$b" 'any(.[]; startswith("tab " + $b))' <<<"$rows" >/dev/null || fail "the shared tab is not offered: $rows"
jq -e --arg a "$a" 'all(.[]; startswith("tab " + $a) | not)' <<<"$rows" >/dev/null || fail "the calling tab is offered: $rows"
jq -e '.[-2] == "window" and .[-1] == "screen"' <<<"$rows" >/dev/null || fail "no window and screen rows: $rows"
[ "$(state | jq -r '.decisions[-1].decision')" = picker ] || fail "WebKit's display question did not reach Copper"
bench share picture window "$shots/picker-window.png" >/dev/null
bench share picture picker "$shots/picker-card-light.png" >/dev/null
bench share picture picker "$shots/picker-card-dark.png" dark >/dev/null
echo "ok the picker offers $(jq length <<<"$rows") rows: $(jq -c . <<<"$rows")"

# 3. A tab.
bench share keys "$(printf 'Slides')" >/dev/null
bench share keys "↩" >/dev/null
r=""
for _ in {1..40}; do r=$(result); [ "$(jq -r '.pending // false' <<<"$r")" != true ] && break; sleep 0.25; done
[ "$(jq -r .ok <<<"$r")" = true ] || fail "sharing the tab failed: $r"
[ "$(jq -r .settings.displaySurface <<<"$r")" = browser ] || fail "displaySurface is not browser: $r"
[ "$(jq -r .label <<<"$r")" = "Slides B (animated)" ] || fail "the track is not named for the tab: $r"
m=$(await "$a" "window.__measure(4)" 4)
jq -e '.fps >= 15 and .distinctPerSec >= 15 and .w <= 1920 and .w > 0' <<<"$m" >/dev/null || fail "the stream is too slow or too big: $m"
[ "$(state | jq -r .pace.held)" = true ] || fail "no latency-critical activity held while sharing: $(state | jq -c .pace)"
echo "ok a tab: $(jq -c '{label, surface: .settings.displaySurface, ms}' <<<"$r") $(jq -c . <<<"$m")"

# 4. The calling tab in front, the shared one behind.
[ "$(state | jq -r '.shares[0].sourceHung')" = true ] || fail "the shared tab was not hung where it paints: $(state | jq -c .stage)"
[ "$(bench eval "$b" "document.hidden")" = false ] || fail "the shared tab thinks it is hidden"
rtc=$(await "$a" "window.__rtc(3)" 6)
jq -e '.encodedFps >= 15' <<<"$rtc" >/dev/null || fail "RTCPeerConnection does not keep up: $rtc"
echo "ok behind the calling tab it keeps coming, and over WebRTC: $(jq -c . <<<"$rtc")"

# 5. The shared tab in front: the bar, and the calling page keeps its pace.
bench select "$b" >/dev/null
sleep 1
[ "$(state | jq -r '.shares[0].consumerHung')" = true ] || fail "the calling page was not kept painting"
bench share picture window "$shots/bar-window.png" >/dev/null
bench share picture bar "$shots/bar-card-dark.png" dark >/dev/null
rtc=$(await "$a" "window.__rtc(3)" 6)
jq -e '.encodedFps >= 15 and .hidden == false' <<<"$rtc" >/dev/null || fail "the calling page slowed behind the shared tab: $rtc"
bench select "$a" >/dev/null
echo "ok with the shared tab in front the call keeps its pace: $(jq -c . <<<"$rtc")"

# 6. The ends.
stopped=$(bench eval "$a" "window.__stopTrack()")
sleep 1
[ "$stopped" = ended ] && [ "$(state | jq '.shares | length')" = 0 ] || fail "track.stop() left Copper capturing: $(state | jq -c .shares)"
[ "$(state | jq -r '.ended[-1].reason')" = "the page stopped it" ] || fail "wrong end: $(state | jq -c '.ended[-1]')"
[ "$(state | jq -r .pace.held)" = false ] || fail "the share's activity outlived it: $(state | jq -c .pace)"
echo "ok track.stop() ends Copper's capture, and gives back its activity"

bench share answer tab "$b" >/dev/null
r=$(share "{ video: true }")
[ "$(jq -r .ok <<<"$r")" = true ] || fail "the second share failed: $r"
bench share stop all >/dev/null
sleep 1
[ "$(bench eval "$a" "window.__ended")" = 1 ] || fail "Stop did not end the track"
echo "ok Stop ends the page's track ('ended')"

bench share answer tab "$b" >/dev/null
bench eval "$a" "window.__ended = 0; 'ok'" >/dev/null
r=$(share "{ video: true }")
[ "$(jq -r .ok <<<"$r")" = true ] || fail "the third share failed: $r"
bench windows closetab "0 $b" >/dev/null
for _ in {1..12}; do [ "$(bench eval "$a" "window.__ended")" = 1 ] && break; sleep 0.25; done
[ "$(bench eval "$a" "window.__ended")" = 1 ] || fail "closing the shared tab did not end the track"
[ "$(state | jq -r '.ended[-1].reason')" = "the shared tab closed" ] || fail "wrong end: $(state | jq -c '.ended[-1]')"
echo "ok closing the shared tab ends the track"

# 7. Cancel, a window, the screen.
bench share answer cancel >/dev/null
r=$(share "{ video: true }")
[ "$(jq -r .name <<<"$r")" = NotAllowedError ] || fail "cancel is not NotAllowedError: $r"
echo "ok cancel: NotAllowedError"
for choice in window screen; do
  bench share answer "$choice" >/dev/null
  r=$(share "{ video: true }")
  decision=$(state | jq -r '.decisions[-1].decision')
  [ "$decision" = "${choice}Prompt" ] || fail "$choice was answered $decision"
  [ "$(jq -r .ok <<<"$r")" = true ] || fail "WebKit's own $choice path failed: $r"
  bench eval "$a" "window.__stopTrack()" >/dev/null
  echo "ok $choice → $decision → WebKit's stream ($(jq -r .label <<<"$r"))"
done

# 8. A cross-origin frame.
b=$(open_tab b.html)
d=$(open_tab d.html)
bench share answer tab "$b" >/dev/null
bench eval "$d" "window.__shareInFrame()" >/dev/null
f=""
for _ in {1..40}; do f=$(bench eval "$d" "JSON.stringify(window.__frameResult)"); [ "$f" != null ] && break; sleep 0.25; done
[ "$(jq -r .ok <<<"$f")" = true ] && [ "$(jq -r .surface <<<"$f")" = browser ] || fail "a frame could not share a tab: $f"
[ "$(state | jq -r '[.decisions[] | select(.decision == "picker")][-1].mainFrame')" = false ] || fail "the frame's request was not the frame's"
bench eval "$d" "window.__measureInFrame(3)" >/dev/null
sleep 4
f=$(bench eval "$d" "JSON.stringify(window.__frameResult)")
jq -e '.fps >= 15' <<<"$f" >/dev/null || fail "the frame's stream is too slow: $f"
# The frame's share id, as if it had leaked: the page around the frame (another origin, the
# same web view) and another tab get nothing for it.
s2=$(state | jq -r '.shares[0].id')
p=$(await "$d" "window.webkit.messageHandlers.copperShare.postMessage({ op: 'frame', share: '$s2', after: 0 })" 5)
jq -e '.ended == true and .data == null' <<<"$p" >/dev/null || fail "the page around the frame got the frame's pictures: $(cut -c1-200 <<<"$p")"
p=$(await "$a" "window.webkit.messageHandlers.copperShare.postMessage({ op: 'frame', share: '$s2', after: 0 })" 5)
jq -e '.ended == true and .data == null' <<<"$p" >/dev/null || fail "another tab got the frame's pictures: $(cut -c1-200 <<<"$p")"
bench eval "$d" "window.webkit.messageHandlers.copperShare.postMessage({ op: 'stop', share: '$s2' }); 'ok'" >/dev/null
sleep 0.5
[ "$(state | jq '.shares | length')" = 1 ] || fail "the page around the frame stopped the frame's share"
bench share stop all >/dev/null
echo "ok a cross-origin frame shares a tab, and only it can use the share: $(jq -c . <<<"$f")"

# 9. Constraints, and what it costs.
bench select "$a" >/dev/null
bench share answer tab "$b" >/dev/null
r=$(share "{ video: { width: { max: 1280 }, height: { max: 720 } } }")
jq -e '.settings.width <= 1280 and .settings.height <= 720' <<<"$r" >/dev/null || fail "constraints were ignored: $(jq -c .settings <<<"$r")"
m=$(await "$a" "window.__measure(3)" 3)
echo "ok constraints: $(jq -c '{w: .settings.width, h: .settings.height}' <<<"$r") $(jq -c . <<<"$m")"
st=$(state)
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF == 3) print ($1 * 60 + $2) * 100 + $3; else print (($1 * 60 + $2) * 60 + $3) * 100 + $4 }'; }
pids="$pid $(jq -r '.processes[0] | "\(.sourceWebPID) \(.consumerWebPID) \(.gpuPID)"' <<<"$st")"
before=(); for p in $pids; do before+=("$(cpu "$p")"); done
sleep 5
i=0; line=""
for p in $pids; do line+="$(( ($(cpu "$p") - ${before[$i]}) / 5 ))% "; i=$((i + 1)); done
echo "ok cost at $(jq -r '.shares[0] | "\(.width)x\(.height) \(.rate) fps"' <<<"$st") (copper, shared page, calling page, GPU; % of a core): $line"
bench eval "$a" "window.__stopTrack()" >/dev/null

# 10. Nothing without a pick.
post() { await "$1" "window.webkit.messageHandlers.copperShare.postMessage($2)" 5; }
nothing() { jq -e '.ended == true and .data == null' <<<"$1" >/dev/null; }
r=$(post "$c" "{ op: 'frame', share: '00112233445566778899aabbccddeeff', after: 0 }")
nothing "$r" || fail "a made-up share id was answered: $(cut -c1-200 <<<"$r")"
last=$(state | jq -c '.decisions[-1]')
bench eval "$c" "window.__planted = 'waiting'; window.webkit.messageHandlers.copperShare.postMessage({ op: 'ask', id: 'planted', video: true }).then(v => window.__planted = JSON.stringify(v)); 'ok'" >/dev/null
sleep 1
[ "$(state | jq -c .picker)" = null ] && [ "$(state | jq -c '.decisions[-1]')" = "$last" ] || fail "an ask alone put a picker up: $(state | jq -c '{picker, d: .decisions[-1]}')"
[ "$(bench eval "$c" "window.__planted")" = waiting ] || fail "an ask alone was answered: $(bench eval "$c" "window.__planted")"
echo "ok a page that posts to Copper itself gets no picture and no picker"

# A share from a fresh calling page whose own pagehide listener, registered before anything
# was shared, silences every other; its share id, as if it had leaked to another page.
a=$(open_tab "a.html?next")
bench select "$a" >/dev/null
bench eval "$a" "window.__noisy = 0; window.addEventListener('pagehide', (e) => { window.__noisy++; e.stopImmediatePropagation(); }, true); 'ok'" >/dev/null
bench share answer tab "$b" >/dev/null
r=$(share "{ video: true }")
[ "$(jq -r .ok <<<"$r")" = true ] || fail "the share for the leak checks failed: $r"
s1=$(state | jq -r '.shares[0].id')
jq -e --arg s "$s1" '(.settings.deviceId // "") | contains($s) | not' <<<"$r" >/dev/null || fail "the track's deviceId gives the share id away: $(jq -c .settings <<<"$r")"
r=$(post "$c" "{ op: 'frame', share: '$s1', after: 0 }")
nothing "$r" || fail "another tab of the same origin got the share's pictures: $(cut -c1-200 <<<"$r")"
bench eval "$d" "window.__postInFrame({ op: 'frame', share: '$s1', after: 0 })" >/dev/null
f=""
for _ in {1..20}; do f=$(bench eval "$d" "JSON.stringify(window.__frameResult)"); [ "$f" != null ] && break; sleep 0.25; done
jq -e '.posted == true and .answer.ended == true and .answer.data == null' <<<"$f" >/dev/null || fail "a frame in another tab got the share's pictures: $(cut -c1-200 <<<"$f")"
bench eval "$c" "window.webkit.messageHandlers.copperShare.postMessage({ op: 'stop', share: '$s1' }); 'ok'" >/dev/null
r=$(post "$c" "{ op: 'tune', share: '$s1', want: { frameRate: 1 } }")
nothing "$r" || fail "another tab could tune the share: $r"
sleep 0.5
[ "$(state | jq -r '.shares[0].fps')" = 30 ] && [ "$(state | jq '.shares | length')" = 1 ] || fail "another tab stopped or slowed the share: $(state | jq -c .shares)"
echo "ok another tab, or a frame in one, can neither see, slow nor stop the share"

# The next document in the same tab: the calling page reloads with its pagehide silenced
# and the share id kept; the share ends as the new document commits, and the id is no good to it.
bench eval "$a" "sessionStorage.setItem('leaked', '$s1'); location.reload(); 'ok'" >/dev/null
for _ in {1..40}; do [ "$(state | jq '.shares | length')" = 0 ] && break; sleep 0.1; done
[ "$(state | jq '.shares | length')" = 0 ] || fail "the share outlived its page: $(state | jq -c .shares)"
reason=$(state | jq -r '.ended[-1].reason')
for _ in {1..40}; do [ "$(bench eval "$a" "document.readyState" 2>/dev/null)" = complete ] && break; sleep 0.25; done
r=$(post "$a" "{ op: 'frame', share: sessionStorage.getItem('leaked'), after: 0 }")
nothing "$r" || fail "the next document got the last one's share: $(cut -c1-200 <<<"$r")"
echo "ok leaving the page ends its share at once ($reason), and the next document gets nothing"

# An ask planted by the page around a frame (another origin, the same web view) is never
# handed the frame's request. The frame calls getDisplayMedia through a fresh about:blank
# frame of its own: the ask comes from that frame, the request from the frame itself — the
# same site, so that ask is the one matched, and the tab goes to the frame that asked.
bench select "$d" >/dev/null
bench eval "$d" "window.__planted = 'waiting'; window.webkit.messageHandlers.copperShare.postMessage({ op: 'ask', id: 'planted', video: true }).then(v => window.__planted = JSON.stringify(v)); 'ok'" >/dev/null
bench eval "$d" "window.__frameResult = null; window.__shareRawInFrame()" >/dev/null
for _ in {1..40}; do [ "$(state | jq -c .picker)" != null ] && break; sleep 0.25; done
pk=$(state | jq -c '{picker, decision: .decisions[-1], asks}')
[ "$(jq -r .picker <<<"$pk")" != null ] || fail "the frame's own call put no picker up: $pk"
jq -e '.decision.ask != "planted" and any(.asks[]; .id == "planted" and .matched == false)' <<<"$pk" >/dev/null \
  || fail "the planted ask was handed the frame's request: $pk"
jq -e '.picker.host == "127.0.0.1" and .picker.within == "localhost"' <<<"$pk" >/dev/null || fail "the picker does not name the frame: $pk"
bench share answer tab "$b" >/dev/null
f=""
for _ in {1..20}; do f=$(bench eval "$d" "JSON.stringify(window.__frameResult)"); [ "$f" != null ] && break; sleep 0.25; done
jq -e '.ok == true and .surface == "browser"' <<<"$f" >/dev/null || fail "the frame did not get its tab: $f"
[ "$(bench eval "$d" "window.__planted")" = waiting ] || fail "the planted ask was answered: $(bench eval "$d" "window.__planted")"
bench share stop all >/dev/null
echo "ok an ask planted by another origin is never matched; the frame's own site's is ($(jq -c '{host: .picker.host, within: .picker.within, ask: .decision.ask, canShareTab: .picker.canShareTab}' <<<"$pk"))"

echo "ok tab share e2e"
