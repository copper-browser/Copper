#!/bin/bash
# Ardia parity, the window's layout, end to end in a headless probe world.
#
#   1. Sidebar on the right (`ui side right`): the column docks at the right
#      edge, the page card moves left with its margin on the left, and the
#      traffic lights ride the column (set in from its left edge as they are
#      from the window's). Back on the left, all three are where they were.
#   2. Folded (⌘S) on the right: the lights hide, the page takes the width;
#      peeking, the column slides out at the right edge.
#   3. Its edge resizes it (`ui width`): the lights follow its left edge.
#   4. A row carried onto the page's left edge lights the leading zone and
#      joins a split there.
#   5. Interface size small / default / large: the rows' measures scale
#      (`sections` geometry), the page keeps its zoom; page frame thin / none.
#   6. The choices survive a relaunch.
#
# A fresh SEARCH_PROBE world; one page from a local server on a free port.
# SEARCH_MCP_PORT (default 4612). ./build.sh first unless COPPER_SKIP_BUILD=1.
# Pictures (both sides × three sizes × light and dark, and the rest) go to
# $SHOTS when set.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="ardialayout-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
tmp="$(mktemp -d)"
pid=""
server=""
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
  [ -n "$server" ] && { kill "$server"; wait "$server"; } 2>/dev/null || true
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }
ok() { echo "ok   $*"; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

# Pages: a big letter on its own colour, served from a port the system picks.
mkdir -p "$tmp/site"
for p in a:#f4d6c8 b:#cfe3f7 c:#d8f0d2; do
  n="${p%%:*}"; c="${p#*:}"
  printf '<!doctype html><title>Page %s</title><body style="margin:0;background:%s;font:bold 120px -apple-system;display:grid;place-items:center;height:100vh"><div>%s</div></body>' \
    "$(echo "$n" | tr a-z A-Z)" "$c" "$(echo "$n" | tr a-z A-Z)" >"$tmp/site/$n.html"
done
python3 - "$tmp/site" "$tmp/port" <<'PY' >/dev/null 2>&1 &
import functools, http.server, sys
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
server=$!
for _ in {1..40}; do [ -s "$tmp/port" ] && break; sleep 0.1; done
port=$(cat "$tmp/port")

S=AAAAAAAA-0000-4000-8000-000000000012
mkdir -p "$folder"
cat >"$folder/session.json" <<JSON
{"active":0,"space":"$S","pins":[],
 "spaces":[{"id":"$S","name":"Layout","hue":0.58}],
 "tabs":[
  {"url":"http://127.0.0.1:$port/a.html","title":"Page A","space":"$S","saved":true,"active":true},
  {"url":"http://127.0.0.1:$port/b.html","title":"Page B","space":"$S","saved":true},
  {"url":"http://127.0.0.1:$port/c.html","title":"Page C","space":"$S","saved":false}]}
JSON
defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
defaults write "$domain" sidebar -bool true
bench() { "$root/bench" --world "$world" "$@"; }
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4612}" "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return 0; sleep 0.5; done
  fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
shot() { [ -n "${SHOTS:-}" ] && bench canvas picture "$SHOTS/$1.png" >/dev/null 2>&1 && echo "     picture $SHOTS/$1.png" || true; }
id() { bench tabs | grep -m1 -F "$1" | grep -oE '[0-9a-f]{8}' | head -1; }
# The layout as `probe` reports it, checked by a Python expression over
# side/size/frame, column [x,y,w,h], stage [x,y,w,h], window [w,h] and lights [[x,mid]…].
check() {
  bench probe >"$tmp/probe.json"
  python3 - "$tmp/probe.json" "$1" "$2" <<'PY' || fail "$2: $(python3 -c "import json,sys; p=json.load(open(sys.argv[1])); print(json.dumps({k: p.get(k) for k in ('layout','lights','folded','peeking','lightsHidden')}))" "$tmp/probe.json")"
import json, sys
p = json.load(open(sys.argv[1])); L = p["layout"]
side, size, frame, column, stage, window, lights = L["side"], L["size"], L["frame"], L["column"], L["stage"], L["window"], p.get("lights") or []
W = window[0]
ok = eval(sys.argv[2])
assert ok, sys.argv[3]
print(f"     {sys.argv[3]}: column {column} stage {stage} lights {[l[0] for l in lights]} window {window}")
PY
}

launch
A=$(id a.html); B=$(id b.html); C=$(id c.html)
[ -n "$A" ] && [ -n "$C" ] || fail "seeded tabs missing: $(bench tabs | head -c 400)"
bench select "$A" >/dev/null
sleep 2

# 1. Left, then right, then left again.
check 'side == "left" and column[0] == 0 and stage[0] >= column[2] and stage[0] + stage[2] == W - 7 and lights[0][0] < 40' "left: column at x 0, page right of it, lights in the corner"
shot left-default-light
w0=$(python3 -c "import json; print(json.load(open('$tmp/probe.json'))['layout']['column'][2])")
bench pace reset >/dev/null
bench ui side right >/dev/null
sleep 1
bench pace | python3 -c "import json,sys; p=json.load(sys.stdin); print('     side switch: busy', p.get('busy'), 'ms, longest pass', p.get('longest'), 'ms')"
check "side == 'right' and column[0] == W - $w0 and column[2] == $w0 and stage[0] == 7 and stage[0] + stage[2] == W - $w0 and lights[0][0] >= W - $w0 + 10 and lights[0][0] < W - $w0 + 40" \
  "right: column at the right edge, page card left with its margin, lights ride the column"
ok "sidebar on the right"
shot right-default-light

# 2. Folded and peeking, on the right.
bench ui folded on >/dev/null
sleep 1
check "p['folded'] and p['lightsHidden'] and stage[0] <= 7 and stage[0] + stage[2] >= W - 7" "folded: the page takes the width"
bench ui peek on >/dev/null
sleep 1
check "p['peeking'] and column[0] == W - $w0" "peeking: the column out at the right edge"
shot right-peek
bench ui peek off >/dev/null
bench ui folded off >/dev/null
sleep 1
check "not p['folded'] and not p['lightsHidden'] and column[0] == W - $w0" "unfolded: back on the right"
ok "fold and peek on the right"

# 3. Wider: the column grows to the left and the lights follow its edge.
bench ui width 300 >/dev/null
sleep 0.6
check "column[2] == 300 and column[0] == W - 300 and lights[0][0] >= W - 300 + 10 and lights[0][0] < W - 300 + 40 and stage[0] + stage[2] == W - 300" "width 300: lights follow the column's left edge"
bench ui width "$w0" >/dev/null
sleep 0.6
ok "resize from the column's left edge"

# 4. A row carried onto the page's left edge joins a split at the leading end.
#    Real mouse events (`split drag`), held over the edge, then let go.
drag=$(bench split drag "$C" 0.06 0.5 hold)
sleep 1
zone=$(bench split state | python3 -c "import json,sys; print(json.load(sys.stdin).get('zone'))")
[ "$zone" = leading ] || fail "a row over the page's left edge: zone $zone ($drag)"
shot right-drop-preview
bench sections release >/dev/null
sleep 1.2
panes=$(bench split state | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)['panes']))")
[ "$panes" = "$C $A" ] || fail "dropped row did not join at the left: '$panes'"
check "stage[0] == 7 and stage[0] + stage[2] == W - $w0" "split: both panes left of the column"
shot right-split
bench split separate >/dev/null
bench select "$A" >/dev/null
sleep 0.8
ok "drop on the page's left edge makes a pane there"

# 5. Interface size and page frame; pictures of both sides at every size, light and dark.
# Rows A and B (one under the other) centre to centre (row + gap), once the column drawn at the new size has handed its frames up.
pitch() {
  local want=$1 got=""
  for _ in {1..20}; do
    got=$(bench probe | python3 -c "import json,sys; L=json.load(sys.stdin)['layout']; r=L['rows']; print(round(r['$B'] - r['$A'], 2), L['row'], json.dumps(r).replace(' ', ''))")
    python3 -c "import sys; p, r = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if abs(p - r * 38 / 34) < 0.6 else 1)" $got 2>/dev/null && break
    sleep 0.25
  done
  echo "$got"
}
for look in light dark; do
  bench ui look "$look" >/dev/null
  for side in right left; do
    bench ui side "$side" >/dev/null
    for size in small default large; do
      bench ui size "$size" >/dev/null
      sleep 0.8
      shot "$side-$size-$look"
      [ "$look$side" = lightright ] && echo "$size $(pitch "$size")" >>"$tmp/pitch"
    done
  done
done
python3 - "$tmp/pitch" <<'PY' || fail "row pitch by size: $(cat "$tmp/pitch")"
import sys
for l in open(sys.argv[1]): print("    ", l.strip())
p = dict((l.split()[0], float(l.split()[1])) for l in open(sys.argv[1]))
assert abs(p["default"] - 38) < 0.6 and p["small"] < p["default"] - 3 and p["large"] > p["default"] + 4, p
print("     row pitch (row + gap):", p)
PY
bench ui look light >/dev/null
bench ui size large >/dev/null
sleep 0.6
check "size == 'large' and side == 'left' and column[0] == 0" "large, left"
bench ui side right >/dev/null
bench ui frame thin >/dev/null
sleep 0.8
check "frame == 'thin' and stage[0] == 3 and stage[0] + stage[2] == W - $w0" "thin frame: 3 pt round the page"
shot right-large-frame-thin
bench ui frame none >/dev/null
sleep 0.8
check "frame == 'none' and stage[0] == 0 and stage[1] == 0 and stage[0] + stage[2] == W - $w0" "no frame: the page edge to edge"
shot right-large-frame-none
ok "interface size and page frame"

# 6. Kept across a relaunch.
bench windows quit >/dev/null 2>&1 || true
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
pid=""
[ "$(defaults read "$domain" sidebar.right)" = 1 ] || fail "sidebar.right not written"
[ "$(defaults read "$domain" interface.size)" = large ] || fail "interface.size not written"
launch
sleep 2
check "side == 'right' and size == 'large' and frame == 'none' and column[0] == W - $w0 and lights[0][0] >= W - $w0 + 10" "relaunch: right, large, no frame"
shot relaunch-right-large
ok "the layout survives a relaunch"
echo "PASS ardia-layout"
