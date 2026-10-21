#!/bin/bash
# Copper's own password list in a sign-in served from another origin inside
# an iframe — the way App Store Connect embeds idmsa.apple.com's — with no
# real account: a probe world whose keychain is a file, and login-frame.html
# served from 127.0.0.1 embedding itself from localhost.
#
#   1. The caret in the frame's email box hangs the list from that box: the
#      frame's site's account (localhost), never the page's (127.0.0.1).
#   2. The list sits over the box inside the frame, not over the page's top.
#   3. Picking the row fills the frame's boxes (the frame tells the page what
#      it holds: the name, and the password's length only).
#   4. A sign-in in the page itself (login.html) still gets the page's account.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="frame-$$"
port="${FIXTURE_PORT:-$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")}"
tmp="$(mktemp -d)"
pid="" server=""
cleanup() {
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.officecommun.search.test.$world.plist"
  rm -rf "$HOME/Library/Application Support/Copper ($world)" "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

(cd "$root/docs/fixtures" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/http.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -fsS -o /dev/null 2>/dev/null "http://127.0.0.1:$port/login-frame.html" && break; sleep 0.25; done
defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
defaults write "com.officecommun.search.test.$world" probe.keychain -string file
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

bench passwords add localhost frame@example.invalid frame-secret-1234 >/dev/null
bench passwords add 127.0.0.1 page@example.invalid page-secret >/dev/null

tab=$(bench open "http://127.0.0.1:$port/login-frame.html" | grep -oE '[0-9a-f]{8}' | head -1)
[ -n "$tab" ] || fail "no tab"
bench wait "$tab" 10 >/dev/null
bench select "$tab" >/dev/null 2>&1 || true
sleep 1.5

# 1. The caret into the frame's email box (the frame focuses it when asked).
rows=""
for _ in {1..20}; do
  bench eval "$tab" 'document.querySelector("iframe").contentWindow.postMessage("focus", "*"); 1' >/dev/null 2>&1 || true
  sleep 0.5
  rows=$(bench bw rows)
  jq -e '.rows | length > 0' <<<"$rows" >/dev/null && break
done
echo "   list: $(jq -c . <<<"$rows")"
jq -e '.rows | length > 0' <<<"$rows" >/dev/null || fail "no list hung from the frame's email box"
[ "$(jq -r .host <<<"$rows")" = localhost ] || fail "the list offers $(jq -r .host <<<"$rows")'s accounts, not the frame's"
row=$(jq -r '.rows[0]' <<<"$rows")
[ "$(jq '.rows | length' <<<"$rows")" = 1 ] || fail "the page's own account was offered in the frame: $(jq -c .rows <<<"$rows")"
echo "ok the caret in the embedded sign-in hangs the frame's site's account ($row), not the page's"

# 2. Over the box inside the frame: the box's spot on the page, in CSS px.
want=$(bench eval "$tab" 'const f = document.querySelector("iframe"), r = f.getBoundingClientRect(), s = getComputedStyle(f); JSON.stringify([r.left + f.clientLeft + parseFloat(s.paddingLeft), r.top + f.clientTop + parseFloat(s.paddingTop)])')
spot=$(jq -c .spot <<<"$rows")
python3 - "$want" "$spot" <<'PY' || fail "the list hangs at $spot, not over the frame's box (frame content starts at $want)"
import json, sys
origin = json.loads(json.loads(sys.argv[1])) if sys.argv[1].startswith('"') else json.loads(sys.argv[1])
x, y, w, h = json.loads(sys.argv[2])
# The email box sits inside the frame: right of and below the frame's content corner, within its 420x260.
sys.exit(0 if origin[0] <= x <= origin[0] + 420 and origin[1] <= y <= origin[1] + 260 and w > 100 else 1)
PY
echo "ok the list hangs over the box inside the frame ($spot; frame content at $want)"

# 3. Picked: the frame's boxes take the account.
bench bw pick "$row" >/dev/null
said=""
for _ in {1..20}; do
  said=$(bench eval "$tab" 'document.getElementById("said").textContent')
  grep -q 'frame@example.invalid' <<<"$said" && break
  sleep 0.25
done
grep -q '"user":"frame@example.invalid"' <<<"$said" || fail "the frame wasn't filled (it says $said)"
grep -q '"passwordLength":17' <<<"$said" || fail "the frame's password box wasn't filled (it says $said)"
echo "ok picking the row fills the name and password inside the frame ($said)"

# 4. The page's own sign-in, as before.
page=$(bench open "http://127.0.0.1:$port/login.html" | grep -oE '[0-9a-f]{8}' | head -1)
bench wait "$page" 10 >/dev/null
bench select "$page" >/dev/null 2>&1 || true
sleep 1
for _ in {1..20}; do
  bench eval "$page" 'document.getElementById("username").focus(); 1' >/dev/null
  sleep 0.5
  rows=$(bench bw rows)
  jq -e '.rows | length > 0' <<<"$rows" >/dev/null && break
done
[ "$(jq -r .host <<<"$rows")" = 127.0.0.1 ] && [ "$(jq '.rows | length' <<<"$rows")" = 1 ] || fail "the page's own sign-in got $(jq -c . <<<"$rows")"
bench bw pick "$(jq -r '.rows[0]' <<<"$rows")" >/dev/null
sleep 1
got=$(bench eval "$page" 'document.getElementById("username").value + " " + document.getElementById("password").value.length')
grep -q 'page@example.invalid 11' <<<"$got" || fail "the page's own sign-in wasn't filled ($got)"
echo "ok a sign-in in the page itself still gets and fills the page's account"
bench select "$tab" >/dev/null 2>&1 || true
[ -n "${COPPER_FRAME_SHOT:-}" ] && bench shot "$tab" "$COPPER_FRAME_SHOT" >/dev/null && echo "ok page drawn to $COPPER_FRAME_SHOT"
echo "ok embedded sign-in e2e"
