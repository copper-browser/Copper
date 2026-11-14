#!/bin/bash
# The bench's measuring hooks (Fork/BenchHooks.swift), each once, in a fresh
# headless probe world:
#
#   1. `ui welcome on` keeps the welcome panel up in a headless world.
#   2. ⎋ in `summon --keys` closes ⌘K; every step says whether it is up.
#   3. `mouse double X Y` on the column's title band zooms the window, and
#      another puts it back (Settings › Desktop & Dock's double-click action
#      is left as it is; with "Minimize" or "None" the answer is all it checks).
#   4. `wheel DY` scrolls a long page by DY, one event per display tick (per
#      timer tick when the display is asleep: it still answers, clock "timer").
#   5. `keylat ⌘k|⎋|⌘t|letter`: handled ≤ commit ≤ frame (no frame while the
#      display is asleep), and the bar or card is up or down after it.
#   6. COPPER_KEEP_SYMBOLS=1 ./build.sh keeps the binary's symbols.
#
# Port 4230 for its agent server (COPPER_MCP_PORT), never the installed
# Copper's. ./build.sh first unless COPPER_SKIP_BUILD=1; COPPER_APP picks
# another build. Fails on a build without the hooks.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="benchhooks-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
port="${COPPER_MCP_PORT:-4230}"
[ "$port" != 4123 ] || { echo "FAIL port 4123 is the installed Copper's"; exit 1; }
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
# One field of a JSON answer (python's repr: True/False, numbers as floats).
field() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$1"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="$port" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

printf '<!doctype html><title>long</title><body style="margin:0"><div style="height:6000px;background:linear-gradient(#fff,#36c)"></div>' >"$tmp/long.html"
id="$(bench open "file://$tmp/long.html")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
sleep 0.5

# 1. The welcome panel, asked for, stays.
bench ui welcome on >/dev/null
sleep 0.5
[ "$(bench probe | field welcome)" = True ] || fail "welcome: headless took the panel down"
bench ui welcome off >/dev/null
echo "ok 1 ui welcome on stays up headless"

# 2. ⎋ closes ⌘K (one press may first clear the highlight, as App.swift's ladder does).
bench summon "" >/dev/null
sleep 0.3
out="$(bench summon "" --keys "⎋⎋")"
[ "$(echo "$out" | field keys.0.key)" = "⎋" ] || fail "summon: ⎋ was not pressed: $out"
[ "$(echo "$out" | field summoning)" = False ] || fail "summon: ⌘K still up after ⎋⎋: $out"
echo "ok 2 summon --keys ⎋ closes the bar ($(echo "$out" | python3 -c 'import json,sys; print([s["summoning"] for s in json.load(sys.stdin)["keys"]])'))"

# 3. A double-click on the column's title band, between the lights' door and
# back/forward. Headless, the window is parked off every screen, so AppKit's
# zoom first takes it somewhere odd, then fills the screen, then puts it back:
# double-click until it is back where it started, and it must have zoomed once.
x=$(( $(bench probe | python3 -c 'import json,sys; print(json.load(sys.stdin)["lights"][-1][0])') + 60 ))
first=""; zoomed=False
for _ in 1 2 3 4; do
  out="$(bench mouse double "$x" 20)"
  [ -n "$first" ] || first="$(echo "$out" | field frameBefore)"
  [ "$(echo "$out" | field action)" = Maximize ] || { echo "ok 3 mouse double answered (double-click action: $(echo "$out" | field action))"; break; }
  [ "$(echo "$out" | field zoomed)" = True ] && zoomed=True
  [ "$(echo "$out" | field frameAfter)" = "$first" ] && break
done
if [ "$(echo "$out" | field action)" = Maximize ]; then
  [ "$zoomed" = True ] || fail "mouse double: the window never zoomed: $out"
  [ "$(echo "$out" | field frameAfter)" = "$first" ] || fail "mouse double: the window did not go back: $out"
  echo "ok 3 mouse double zooms and puts back"
fi

# 4. The wheel scrolls the page by about DY.
[ "$(bench eval "$id" 'scrollY')" = 0 ] || fail "wheel: page not at the top"
t0=$(date +%s)
out="$(bench wheel 600 --steps 30)"
[ "$(echo "$out" | field events)" = 30 ] || fail "wheel: not 30 events: $out"
[ $(( $(date +%s) - t0 )) -le 5 ] || fail "wheel: took $(( $(date +%s) - t0 )) s for 30 events"
sleep 0.5
y="$(bench eval "$id" 'Math.round(scrollY)')"
python3 -c "import sys; sys.exit(0 if 400 <= $y <= 800 else 1)" || fail "wheel: page scrolled $y, not ~600"
echo "ok 4 wheel scrolled $y px at $(echo "$out" | field hz) Hz by $(echo "$out" | field clock), display asleep $(echo "$out" | field display_asleep) (ticks $(echo "$out" | field tick_ms), missed $(echo "$out" | field missed_ticks))"

# 5. Key → commit → frame.
bench ui focus none >/dev/null
lat() {
  out="$(bench keylat "$1")"
  echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)
assert 0 <= d["handled_ms"] <= d["commit_ms"] <= d.get("frame_ms", d["commit_ms"]) < 1000, d
assert "frame_ms" in d or d["display_asleep"], d' || fail "keylat $1: times out of order: $out"
  [ "$(echo "$out" | field "$2")" = "$3" ] || fail "keylat $1: $2 is not $3: $out"
  echo "   $1 handled $(echo "$out" | field handled_ms) commit $(echo "$out" | field commit_ms) frame $(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frame_ms", "— (display asleep)"))') ms"
}
lat "⌘k" summoning True
lat "a" summoning True
lat "⎋" changed True
bench probe | grep -q '"summoning": false' || lat "⎋" summoning False
lat "⌘t" launching True
lat "⎋" launching False
echo "ok 5 keylat orders handled ≤ commit ≤ frame"

# 6. Symbols kept on request.
if [ "${COPPER_KEEP_SYMBOLS:-}" = 1 ]; then
  [ "$(nm "$app" 2>/dev/null | grep -c BenchHooks)" -gt 0 ] || fail "COPPER_KEEP_SYMBOLS=1: the binary was stripped"
  echo "ok 6 COPPER_KEEP_SYMBOLS=1 kept the symbols"
else
  grep -q 'COPPER_KEEP_SYMBOLS' "$root/build.sh" || fail "build.sh has no COPPER_KEEP_SYMBOLS"
  echo "ok 6 build.sh knows COPPER_KEEP_SYMBOLS (set it to check the binary)"
fi
echo PASS
