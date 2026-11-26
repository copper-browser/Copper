#!/bin/bash
# Ardia parity polish, end to end:
#
#   1. Mini player: a tab playing sound that you leave gets the sidebar's
#      strip — the page's Now Playing title, artist and artwork, play/pause,
#      ±15 s — and ✕ puts it away.
#   2. Auto-float: leaving the window (Copper to the back, or covered) lifts
#      a video you can hear into the floating window on any site, and coming
#      back lands it; a muted video stays where it is.
#   3. What's New: the card on a newer version's first launch, not on a
#      relaunch of the same one.
#   4. Translate offer: a French page (the Mac reads English) gets the
#      banner, once a site; Translate starts translating; an English page
#      gets none.
#   5. Pages opened in Little Copper and in Peek go into History.
#
# A fresh SEARCH_PROBE world, headless; a local page server, no network. The
# real Copper is never touched. ./build.sh first unless COPPER_SKIP_BUILD=1
# (COPPER_APP=… picks a built app); SHOTS=DIR keeps pictures there (the
# strip, the card, the banner, the onboarding's look page).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="polish-$$"
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
shots="${SHOTS:-}"
[ -n "$shots" ] && mkdir -p "$shots"

# The pages. A 60 s tone, nearly silent; a film drawn on a canvas with a
# tone under it (no video file needed); a French page and an English one.
web_port="${POLISH_WEB_PORT:-$((20000 + $$ % 20000))}"
mkdir -p "$tmp/site"
python3 - "$tmp/site" <<'PY'
import math, struct, sys, wave, zlib
site = sys.argv[1]
with wave.open(f"{site}/tone.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(b"".join(struct.pack("<h", int(60 * math.sin(2 * math.pi * 440 * i / 8000))) for i in range(8000 * 60)))
def png(path, rgb, n=64):
    raw = b"".join(b"\0" + bytes(rgb) * n for _ in range(n))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
png(f"{site}/art.png", (214, 110, 60))
PY
cat >"$tmp/site/player.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Tone radio</title><body style="font:16px -apple-system;padding:40px">
<h1>Tone radio</h1><audio id="a" src="tone.wav" loop controls></audio>
<script>
navigator.mediaSession.metadata = new MediaMetadata({ title: 'A Quiet Tone', artist: 'Copper Fixtures', album: 'Polish', artwork: [{ src: 'art.png', sizes: '64x64', type: 'image/png' }] });
</script></body>
HTML
cat >"$tmp/site/film.html" <<'HTML'
<!doctype html><title>Film</title><body style="margin:0;background:#111">
<video id="v" width="640" height="360" playsinline></video><canvas id="c" width="320" height="180" style="display:none"></canvas>
<script>
var c = document.getElementById('c'), g = c.getContext('2d'), n = 0;
setInterval(function () { n++; g.fillStyle = 'hsl(' + (n * 7 % 360) + ',60%,50%)'; g.fillRect(0, 0, 320, 180); }, 40);
function start(muted) {
  var stream = c.captureStream(25), ac = new AudioContext(), o = ac.createOscillator(), gain = ac.createGain(), out = ac.createMediaStreamDestination();
  gain.gain.value = 0.002; o.connect(gain); gain.connect(out); o.start();
  stream.addTrack(out.stream.getAudioTracks()[0]);
  var v = document.getElementById('v'); v.srcObject = stream; v.muted = !!muted; v.play();
  return 'started';
}
</script></body>
HTML
cat >"$tmp/site/fr.html" <<'HTML'
<!doctype html><html lang="fr"><meta charset="utf-8"><title>Le Jardin des Plantes</title><body style="font:16px Georgia;padding:40px;max-width:640px">
<h1>Le Jardin des Plantes</h1>
<p>Le Jardin des Plantes est le principal jardin botanique de France. Il a été créé en 1635 par Guy de La Brosse, médecin du roi Louis XIII, pour y cultiver des plantes médicinales.</p>
<p>Ouvert au public en 1640, il abrite aujourd'hui des serres, une ménagerie, des galeries d'histoire naturelle et des milliers d'espèces venues du monde entier. Les promeneurs y viennent en toute saison.</p>
</body></html>
HTML
cat >"$tmp/site/en.html" <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><title>The Botanical Garden</title><body style="font:16px Georgia;padding:40px;max-width:640px">
<h1>The Botanical Garden</h1>
<p>The garden was founded in 1635 to grow medicinal plants, and it opened to the public a few years later. Today it holds glasshouses, a small zoo and natural history galleries.</p>
<p>Visitors come in every season to walk among thousands of species gathered from all over the world.</p>
</body></html>
HTML
for page in little peek; do printf '<!doctype html><title>%s page</title><body><h1>Opened in %s</h1></body>' "$page" "$page" >"$tmp/site/$page.html"; done
(cd "$tmp/site" && exec python3 -m http.server "$web_port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
site="http://127.0.0.1:$web_port"
other="http://localhost:$web_port"

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
COPPER_MAIN_WORLD="$world" SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4616}" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
curl -fsS "$site/player.html" >/dev/null || fail "page server did not start"
bench ui sidebar on >/dev/null # the player and the card live in the column

# A page as a person's tab (not the bench's), in front; its id once loaded.
visit() {
  bench windows open 0 "$1" >/dev/null
  local id=""
  for _ in {1..40}; do
    id="$(bench windows | json "next((i for i, u in zip(d['windows'][0]['tabIDs'], d['windows'][0]['tabs']) if u == '$1'), '')")"
    [ -n "$id" ] && break; sleep 0.25
  done
  [ -n "$id" ] || fail "no tab for $1: $(bench windows)"
  bench wait "$id" 15 >/dev/null
  echo "$id"
}
player() { bench player "$@"; }
shot() { [ -n "$shots" ] && bench canvas picture "$shots/$1.png" >/dev/null 2>&1 || true; }

# 1. The mini player.
radio="$(visit "$site/player.html")"
bench eval "$radio" "document.getElementById('a').play(), 'ok'" >/dev/null
for _ in {1..40}; do [ "$(player | json 'd["tab"] != ""')" = True ] && break; sleep 0.25; done
[ "$(player | json 'd["shown"]')" = False ] || fail "the strip shows for the tab in front: $(player)"
visit "$site/en.html" >/dev/null
for _ in {1..40}; do [ "$(player | json 'd["shown"] and d["title"] == "A Quiet Tone"')" = True ] && break; sleep 0.25; done
p="$(player)"
[ "$(echo "$p" | json 'd["shown"] and d["playing"]')" = True ] || fail "no strip for the tab left playing: $p"
[ "$(echo "$p" | json 'd["artist"]')" = "Copper Fixtures" ] || fail "artist: $p"
echo "$p" | json 'd["artwork"]' | grep -q "/art.png$" || fail "artwork: $p"
echo "ok mini player: $(echo "$p" | json '"%s — %s, playing %s, %.0f/%.0f s" % (d["title"], d["artist"], d["playing"], d["at"], d["length"])')"
sleep 1; shot mini-player
at="$(player | json 'd["at"]')"
player skip 15 >/dev/null; sleep 1.2
after="$(player | json 'd["at"]')"
python3 -c "import sys; sys.exit(0 if $after - $at >= 14 else 1)" || fail "+15 s moved $at → $after"
player toggle >/dev/null
for _ in {1..20}; do [ "$(player | json 'd["playing"]')" = False ] && break; sleep 0.25; done
[ "$(player | json 'd["playing"]')" = False ] || fail "pause: $(player)"
bench eval "$radio" "document.getElementById('a').paused" | grep -qE '^(true|1)$' || fail "the page's audio did not pause"
player toggle >/dev/null
for _ in {1..20}; do [ "$(player | json 'd["playing"]')" = True ] && break; sleep 0.25; done
[ "$(player | json 'd["playing"]')" = True ] || fail "play: $(player)"
echo "ok mini player: +15 s ($at → $after s), pause and play reach the page"
player hide >/dev/null
[ "$(player | json 'd["shown"]')" = False ] || fail "✕ left the strip up"
bench eval "$radio" "document.getElementById('a').pause(), 'ok'" >/dev/null
echo "ok mini player: ✕ puts it away"

# 2. Leaving the window floats a video you can hear, on any site; back lands it.
film="$(visit "$site/film.html")"
bench eval "$film" "start(false)" >/dev/null
sleep 1.5
player away >/dev/null
for _ in {1..20}; do [ "$(player | json 'd["floating"]')" = True ] && break; sleep 0.25; done
[ "$(player | json 'd["floating"]')" = True ] || fail "leaving the window did not float the video: $(player)"
echo "ok auto-float: left the window → the video floats ($site is no known player)"
player back >/dev/null
for _ in {1..20}; do [ "$(player | json 'd["floating"]')" = False ] && break; sleep 0.25; done
[ "$(player | json 'd["floating"]')" = False ] || fail "coming back did not land it: $(player)"
echo "ok auto-float: back → it lands in its tab"
bench eval "$film" "document.getElementById('v').pause(), 'ok'" >/dev/null
muted="$(visit "$other/film.html")"
bench eval "$muted" "start(true)" >/dev/null
sleep 1.5
player away >/dev/null; sleep 1.5
[ "$(player | json 'd["floatingAny"]')" = False ] || fail "a muted video floated: $(player)"
player back >/dev/null
echo "ok auto-float: a muted video stays put"

# 3. What's New, once, after an update.
w="$(bench updates whatsnew launch 0.9)"
[ "$(echo "$w" | json 'd["showing"]')" = True ] || fail "no card after 0.9 → current: $w"
bench updates whatsnew show 1.0.20261125.140 "Little Copper and Peek pages go into History, and the sidebar has a mini player for the tab you left playing." >/dev/null
sleep 1; shot whats-new
if [ -n "$shots" ]; then bench ui sidebar off >/dev/null; sleep 1; shot whats-new-tabstrip; bench ui sidebar on >/dev/null; fi
w="$(bench updates whatsnew launch "$(echo "$w" | json 'd["current"]')")"
[ "$(echo "$w" | json 'd["showing"]')" = False ] || fail "a card on a relaunch of the same version: $w"
echo "ok what's new: shown after 0.9 → $(echo "$w" | json 'd["current"]'), not on a relaunch"

# 4. Translate: offered on a French page, once a site; none on an English one.
bench page offer reset >/dev/null
visit "$site/en.html" >/dev/null; sleep 2
[ "$(bench page offer | json 'd["showing"]')" = False ] || fail "an offer on an English page: $(bench page offer)"
fr="$(visit "$other/fr.html")"
for _ in {1..40}; do [ "$(bench page offer | json 'd["showing"]')" = True ] && break; sleep 0.25; done
o="$(bench page offer)"
[ "$(echo "$o" | json 'd["showing"] and d["offer"]["from"]')" = French ] || fail "no offer on the French page: $o"
sleep 0.5; shot translate-offer
echo "ok translate: offered on $other/fr.html (from French), none on the English page"
bench page offer no >/dev/null
bench go "$fr" "$other/fr.html?again" >/dev/null 2>&1 || bench windows open 0 "$other/fr.html?again" >/dev/null
sleep 2.5
[ "$(bench page offer | json 'd["showing"]')" = False ] || fail "offered twice on one site: $(bench page offer)"
bench page offer reset >/dev/null
fr="$(visit "$other/fr.html?third")"
for _ in {1..40}; do [ "$(bench page offer | json 'd["showing"]')" = True ] && break; sleep 0.25; done
bench page offer yes >/dev/null
sleep 1
s="$(bench page state)"
[ "$(echo "$s" | json 'd["translated"] or d.get("state") in ("preparing", "translating", "done", "waiting", "failed")')" = True ] || fail "Translate did not start: $s"
echo "ok translate: not offered again on the site; Translate → $(echo "$s" | json 'd.get("state", "")') ($(echo "$s" | json 'd.get("languages", "")'))"

# 5. Little Copper and Peek go into History.
bench little open "$site/little.html" >/dev/null
bench peek open "$site/peek.html" >/dev/null
for _ in {1..40}; do
  grep -q "peek.html" "$folder/history.json" 2>/dev/null && grep -q "little.html" "$folder/history.json" && break; sleep 0.25
done
grep -q "little.html" "$folder/history.json" || fail "Little Copper's page is not in History"
grep -q "peek.html" "$folder/history.json" || fail "Peek's page is not in History"
echo "ok history: Little Copper's and Peek's pages are in History"
bench peek close >/dev/null; bench little close >/dev/null

# The onboarding's look page, as a picture.
if [ -n "$shots" ]; then
  bench ui welcomepage 2 >/dev/null; sleep 1.5; shot welcome-look; bench ui welcome off >/dev/null
fi
echo PASS
