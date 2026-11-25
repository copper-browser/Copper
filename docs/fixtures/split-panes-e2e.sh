#!/bin/bash
# Split view: three panes, side by side or stacked, kept across a relaunch.
#
#   1. ⇧⌘D's path (`split ID`) makes a two-pane split; a third tab joins it at
#      the right edge; the three pages sit in a row, then stacked (rotate),
#      then in the other order (flip).
#   2. ⌘Q writes the split into the session (one token, each pane's slot);
#      a relaunch brings it back stacked, in the same order, on screen.
#   3. A sidebar row dragged by real mouse events onto the page's right edge
#      shows where its pane would go, and joins the split when let go.
#   4. A real ⌥-click on a link (`split click SELECTOR`) opens it in a new pane.
#   5. Separate all: the split ends, every tab stays.
#
# A fresh SEARCH_PROBE world, headless; pages from a local server on
# SPLIT_PORT (4605). ./build.sh first unless COPPER_SKIP_BUILD=1.
# SPLIT_SHOTS=DIR keeps window pictures of each step.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="splitpanes-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
port="${SPLIT_PORT:-4605}"
shots="${SPLIT_SHOTS:-}"
[ -n "$shots" ] && mkdir -p "$shots"
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
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
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

# Five pages, each one big letter on its own colour.
mkdir -p "$tmp/site"
for p in a:#f4d6c8 b:#cfe3f7 c:#d8f0d2 d:#efe0f7 e:#f7f1c9; do
  n="${p%%:*}"; c="${p#*:}"
  printf '<!doctype html><title>%s</title><body style="margin:0;background:%s;font:bold 160px -apple-system;display:grid;place-items:center;height:100vh"><div>%s<br><a id="go" href="e.html" style="font-size:24px">to E</a></div></body>' \
    "$(echo "$n" | tr a-z A-Z)" "$c" "$(echo "$n" | tr a-z A-Z)" >"$tmp/site/$n.html"
done
(cd "$tmp/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
server=$!
for _ in {1..20}; do curl -fs "http://127.0.0.1:$port/a.html" >/dev/null && break; sleep 0.25; done

S=AAAAAAAA-0000-4000-8000-000000000005
mkdir -p "$folder"
cat >"$folder/session.json" <<JSON
{"active":0,"space":"$S","pins":[],
 "spaces":[{"id":"$S","name":"Split","hue":0.08}],
 "tabs":[
  {"url":"http://127.0.0.1:$port/a.html","title":"A","space":"$S","saved":true,"active":true},
  {"url":"http://127.0.0.1:$port/b.html","title":"B","space":"$S","saved":true},
  {"url":"http://127.0.0.1:$port/c.html","title":"C","space":"$S","saved":true},
  {"url":"http://127.0.0.1:$port/d.html","title":"D","space":"$S","saved":false}]}
JSON

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
defaults write "$domain" sidebar -bool true
bench() { "$root/bench" --world "$world" "$@"; }
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return 0; sleep 0.5; done
  fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
# A tab's short id by its title (`bench tabs` prints "● ID  TITLE  URL").
id() { bench tabs | python3 -c "import re,sys; m=[re.match(r'^\S?\s*([0-9a-f]{8})\s+(\S+)', l) for l in sys.stdin]; t=[x.group(1) for x in m if x and x.group(2)==sys.argv[1]]; print(t[0] if t else '')" "$1"; }
state() { bench split state; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d$1))"; }
shot() { [ -n "$shots" ] && bench canvas picture "$shots/$1.png" >/dev/null 2>&1 || true; }
# Panes' frames in a row: one y, x increasing; stacked: one x, y decreasing (AppKit counts up).
cat >"$tmp/layout.py" <<'PY'
import json, sys
s = json.load(sys.stdin); want = sys.argv[1]
f = s["frames"]
assert len(f) == len(s["panes"]), f"frames {f} for panes {s['panes']}"
assert [x["tab"] for x in f] == s["panes"]
if want == "row":
    assert len({x["y"] for x in f}) == 1 and all(a["x"] + a["w"] < b["x"] for a, b in zip(f, f[1:])), f
else:
    assert len({x["x"] for x in f}) == 1 and all(a["y"] > b["y"] + b["h"] for a, b in zip(f, f[1:])), f
print(" ".join(f"{x['tab']}@{x['x']},{x['y']} {x['w']}x{x['h']}" for x in f))
PY
layout() { python3 "$tmp/layout.py" "$1"; }

launch
A=$(id A); B=$(id B); C=$(id C); D=$(id D)
[ -n "$A" ] && [ -n "$D" ] || fail "seeded tabs missing: $(bench tabs | head -c 400)"
bench select "$A" >/dev/null
sleep 1

# 1. Two panes, a third at the right edge, then stacked, then flipped.
bench pace reset >/dev/null
bench split "$B" >/dev/null
sleep 1.2
bench pace >"$tmp/pace2.json"
python3 - "$tmp/pace2.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); steps = dict((s[0], s[1]) for s in p["steps"])
end = max(v for k, v in steps.items() if k.startswith("split."))
print(f"     open→last split step {end - steps['split.open']:.1f} ms, longest main-thread pass {p['longest']} ms, steps {[s for s in p['steps'] if s[0].startswith('split.')]}")
PY
[ "$(state | field '["panes"]')" = "[\"$A\", \"$B\"]" ] || fail "two panes: $(state)"
state | layout row >/dev/null || fail "two panes not side by side: $(state)"
ok "two panes side by side"
bench pace reset >/dev/null
bench split "$C" right >/dev/null
sleep 1
bench pace | python3 -c "import json,sys; p=json.load(sys.stdin); print('     join: longest pass', p['longest'], 'ms, steps', [s for s in p['steps'] if s[0].startswith('split.')])"
[ "$(state | field '["panes"]')" = "[\"$A\", \"$B\", \"$C\"]" ] || fail "three panes: $(state)"
out=$(state | layout row) || fail "three panes not in a row: $(state)"; echo "     row: $out"
shot 1-row3
ok "three panes in a row"
bench split rotate >/dev/null
sleep 0.8
out=$(state | layout stack) || fail "three panes not stacked: $(state)"; echo "     stack: $out"
shot 2-stack3
ok "three panes stacked"
bench split flip >/dev/null
sleep 0.3
[ "$(state | field '["panes"]')" = "[\"$C\", \"$B\", \"$A\"]" ] || fail "flip: $(state)"
ok "flipped: C B A"
bench split shares 0.5,0.3,0.2 >/dev/null
sleep 0.3
[ "$(bench split "$D" bottom | field '["panes"]')" = "[\"$C\", \"$B\", \"$A\"]" ] || fail "a fourth pane got in"
ok "a split holds three panes"

# 2. ⌘Q writes it; the relaunch brings it back, stacked, same order and shares.
bench windows quit >/dev/null 2>&1 || true
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
pid=""
python3 - "$folder/session.json" <<'PY' || fail "session: $(cat "$folder/session.json" | head -c 600)"
import json, sys
tabs = json.load(open(sys.argv[1]))["tabs"]
kept = [t for t in tabs if t.get("split")]
assert len(kept) == 3 and len({t["split"] for t in kept}) == 1, kept
order = sorted(kept, key=lambda t: t["pane"]["at"])
assert [t["title"] for t in order] == ["C", "B", "A"], order
assert all(t["pane"].get("stacked") for t in kept)
assert [t["pane"]["share"] for t in order] == [0.5, 0.3, 0.2], order
print("     session:", [(t["title"], t["pane"]) for t in order])
PY
ok "session keeps order, stack and shares"
launch
sleep 1.5
A=$(id A); B=$(id B); C=$(id C); D=$(id D)
s=$(state)
[ "$(echo "$s" | field '["panes"]')" = "[\"$C\", \"$B\", \"$A\"]" ] || fail "relaunch: $s"
[ "$(echo "$s" | field '["stacked"]')" = "true" ] || fail "relaunch not stacked: $s"
out=$(echo "$s" | layout stack) || fail "relaunch layout: $s"; echo "     relaunch: $out"
ok "relaunch: the split is back, stacked, C B A"

# 3. A sidebar row carried onto the page's right edge, by real mouse events.
bench split separate >/dev/null
sleep 0.5
[ "$(state | field '["kept"]')" = "[]" ] || fail "separate: $(state)"
ok "separate all: no split kept"
bench select "$A" >/dev/null
sleep 0.5
drag=$(bench split drag "$D" 0.93 0.5 hold)
sleep 1
zone=$(state | field '["zone"]')
[ "$zone" = '"trailing"' ] || fail "drag over the right edge: zone $zone ($drag)"
shot 3-drop-preview
bench sections release >/dev/null
sleep 1
[ "$(state | field '["panes"]')" = "[\"$A\", \"$D\"]" ] || fail "dropped row did not join: $(state) ($drag)"
shot 4-dropped
ok "row dragged to the right edge became a pane"

# 4. A real ⌥-click on A's link: E opens in a new pane beside A.
bench split click '#go' >/dev/null
sleep 1.5
n=$(state | python3 -c "import json,sys; print(len(json.load(sys.stdin)['panes']))")
[ "$n" = 3 ] || fail "link did not open a pane: $(state)"
ok "⌥-click opened a third pane"
shot 5-link
echo "PASS split-panes"
