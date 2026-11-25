#!/bin/bash
# Profiles keep their own extensions, passwords and history (Ardia parity,
# docs/spaces.md › Profiles). A fresh SEARCH_PROBE world, headless, with two
# spaces — Home (Shared) and Work (profile "Work") — a page each from a local
# server on PROFILES_PORT (4611), and the probe keychain file standing in for
# the keychain. No network, no real Copper world or keychain touched.
#
#   1. What was there before profiles — a saved password, a visited place —
#      is seen from both spaces.
#   2. An unpacked extension installed with Work in front runs only in Work's
#      tabs (its content script marks the page); `profiles all` runs it in
#      Home too; `profiles shared` takes it out of Work.
#   3. A password saved in Work is listed and filled only in Work; one saved
#      in Home is seen in both; Work changing Home's login changes it for both.
#   4. A page visited in Work is in Work's history only; one in Home, in both.
#   5. ⌥⌘→ and ⌥⌘← (real key events through the app) switch to the next and
#      previous space, and the profile in front follows.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="profiles-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
port="${PROFILES_PORT:-4611}"
tmp="$(mktemp -d)"
pid=""
server=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
  rm -rf "$folder"
  # The world's WebKit stores: Shared's (Store.probeStore, FNV-1a 32 of the
  # world) and Work's jar and extension storage (Spaces.storeID, FNV-1a 64
  # of "world\x01Work").
  local kit="$HOME/Library/WebKit/com.collinrijock.copper.dev" stem
  for stem in $(python3 - "$world" <<'PY'
import sys
w = sys.argv[1]
h = 2166136261
for b in w.encode(): h = ((h ^ b) * 16777619) & 0xFFFFFFFF
print('5E4C%04X-%04X' % (h >> 16, h & 0xFFFF))
h = 14695981039346656037
for b in (w + '\x01Work').encode(): h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
for kind in (0xC0FFEE00, 0xC0FFEE01):
    print('%08X-%04X-4000-8000-%012X' % (kind, (h >> 48) & 0xFFFF, h & 0xFFFFFFFFFFFF))
PY
); do
    rm -rf "$kit/WebExtensions/$stem"* "$kit/WebsiteDataStore/$(tr 'A-F' 'a-f' <<<"$stem")"* "$kit/WebsiteDataStore/$stem"*
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; [ -f "$tmp/copper.log" ] && tail -5 "$tmp/copper.log"; exit 1; }
ok() { echo "ok   $*"; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

# Pages, each titled by its name.
mkdir -p "$tmp/site"
for n in home work home-only work-only; do
  printf '<!doctype html><title>%s</title><p>%s</p>\n' "$n" "$n" >"$tmp/site/$n.html"
done
(cd "$tmp/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
server=$!
for _ in {1..40}; do curl -fs "http://127.0.0.1:$port/home.html" >/dev/null && break; sleep 0.25; done
curl -fs "http://127.0.0.1:$port/home.html" >/dev/null || fail "local page server did not start on $port"
web="http://127.0.0.1:$port"

# A content script that marks every page it runs in.
mkdir -p "$tmp/ext"
cat >"$tmp/ext/manifest.json" <<'JSON'
{ "manifest_version": 3, "name": "Copper profiles fixture", "version": "1.0",
  "host_permissions": ["<all_urls>"],
  "content_scripts": [{ "matches": ["<all_urls>"], "run_at": "document_end", "js": ["content.js"] }] }
JSON
echo 'document.documentElement.dataset.copperFixture = "here";' >"$tmp/ext/content.js"

# The world: two spaces, a page each; a password and a place from before profiles.
H=AAAAAAAA-0000-4000-8000-0000000000A1
W=AAAAAAAA-0000-4000-8000-0000000000A2
mkdir -p "$folder"
cat >"$folder/session.json" <<JSON
{"active":0,"space":"$H","pins":[],
 "spaces":[{"id":"$H","name":"Home","hue":0.08},{"id":"$W","name":"Work","hue":0.6,"profile":"Work"}],
 "tabs":[
  {"url":"$web/home.html","title":"home","space":"$H","saved":true,"active":true},
  {"url":"$web/work.html","title":"work","space":"$W","saved":true,"active":true}]}
JSON
echo '[{"url":"https://old.example/page","key":"old.example/page","title":"Old page","count":3,"last":785000000}]' >"$folder/history.json"
echo '{"passwords":[{"host":"old.test","user":"o","password":"pw-old"}],"passkeys":[]}' >"$folder/probe-keychain.json"
chmod 600 "$folder/probe-keychain.json"

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
defaults write "$domain" sidebar -bool true
defaults write "$domain" probe.keychain -string file
bench() { "$root/bench" --world "$world" "$@"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start"

# The tab at an address (a prefix), among the window's tabs.
tab_at() { bench tabs | grep -F -- "$1" | tail -1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{8}$/) { print $i; exit } }'; }
space() { bench spaces select "$1" >/dev/null; sleep 0.6; }
current() { bench spaces | awk '/^●/ { print $3; exit }'; }
front() { bench passwords status | jq -r '.profile'; }
history_has() { bench spaces history "$1" | jq -e --arg k "$2" '.places | any(contains($k))' >/dev/null; }
pw_list() { bench passwords list | jq -c '[.logins[] | "\(.host)@\(.profile)"] | sort'; }
check() { bench passwords check "$1" "$2" "$3" | jq -r '.matches'; }
mark() { bench eval "$1" 'document.documentElement.dataset.copperFixture || "none"'; }
# Goes there and waits for the page; the content script runs at document_end.
visit() { bench go "$1" "$2" >/dev/null; bench wait "$1" 10 >/dev/null 2>&1 || true; sleep 0.8; }
runs() { bench extensions | jq -c --arg id "$1" '.extensions[] | select(.id == $id) | .runs'; }
await_runs() {
  local want="$2"
  for _ in {1..40}; do [ "$(runs "$1")" = "$want" ] && return 0; sleep 0.25; done
  return 1
}

space Home
home=$(tab_at "$web/home.html"); [ -n "$home" ] || fail "no Home tab: $(bench tabs | head -c 300)"
bench wait "$home" 10 >/dev/null 2>&1 || true
space Work
work=$(tab_at "$web/work.html"); [ -n "$work" ] || fail "no Work tab: $(bench tabs | head -c 300)"
bench wait "$work" 10 >/dev/null 2>&1 || true
[ "$(front)" = Work ] || fail "the profile in front in Work is '$(front)'"

# 1. From before profiles: seen everywhere.
history_has old old.example/page || fail "Work doesn't see the place from before profiles"
[ "$(check old.test o pw-old)" = true ] || fail "Work can't fill the password from before profiles"
space Home
[ "$(front)" = "" ] || fail "the profile in front in Home is '$(front)'"
history_has old old.example/page || fail "Home doesn't see the place from before profiles"
[ "$(check old.test o pw-old)" = true ] || fail "Home can't fill the password from before profiles"
ok "1 a password and a place from before profiles are seen in both"

# 2. Extensions.
space Work
bench ext-folder "$tmp/ext" --yes >/dev/null
ext=""
for _ in {1..40}; do
  ext=$(bench extensions | jq -r '.extensions[] | select(.name == "Copper profiles fixture") | .id')
  [ -n "$ext" ] && break; sleep 0.25
done
[ -n "$ext" ] || fail "fixture extension did not install"
await_runs "$ext" '["Work"]' || fail "installed from Work, it runs in $(runs "$ext")"
[ "$(bench extensions | jq -c --arg id "$ext" '.extensions[] | select(.id == $id) | .profiles')" = '["Work"]' ] || fail "its profiles aren't [Work]"
visit "$work" "$web/work.html?2"
[ "$(mark "$work")" = here ] || fail "its content script didn't run in Work's page"
space Home
visit "$home" "$web/home.html?2"
[ "$(mark "$home")" = none ] || fail "a Work extension ran in Home's page"
ok "2a installed with Work in front: runs in Work's tab only"
bench ext-manager profiles "$ext" all >/dev/null
await_runs "$ext" '["","Work"]' || fail "with every profile on, it runs in $(runs "$ext")"
visit "$home" "$web/home.html?3"
[ "$(mark "$home")" = here ] || fail "on for every profile, it didn't run in Home's page"
ok "2b every profile: runs in Home too"
bench ext-manager profiles "$ext" shared >/dev/null
await_runs "$ext" '[""]' || fail "Shared only, it runs in $(runs "$ext")"
space Work
visit "$work" "$web/work.html?3"
[ "$(mark "$work")" = none ] || fail "taken out of Work, it still ran in Work's page"
ok "2c Shared only: out of Work"

# 3. Passwords (Work in front).
bench passwords add work.test me pw-work >/dev/null
[ "$(check work.test me pw-work)" = true ] || fail "Work can't fill its own password"
pw_list | grep -q '"work.test@Work"' || fail "Work's list lacks its password: $(pw_list)"
space Home
[ "$(check work.test me pw-work)" = false ] || fail "Home can fill Work's password"
pw_list | grep -q 'work.test' && fail "Home lists Work's password: $(pw_list)"
bench passwords add home.test you pw-home >/dev/null
space Work
[ "$(check home.test you pw-home)" = true ] || fail "Work can't fill a Shared password"
bench passwords add home.test you pw-new >/dev/null
space Home
[ "$(check home.test you pw-new)" = true ] || fail "Work's change to a Shared login didn't reach Home"
jq -c '[.passwords[] | "\(.host)@\(.profile // "")"] | sort' "$folder/probe-keychain.json" >"$tmp/drawers.json"
[ "$(cat "$tmp/drawers.json")" = '["home.test@","old.test@","work.test@Work"]' ] || fail "drawers: $(cat "$tmp/drawers.json")"
echo "     drawers on disk: $(cat "$tmp/drawers.json")"
ok "3 passwords: Work's stay in Work, Shared's are everyone's"

# 4. History.
visit "$home" "$web/home-only.html"
space Work
visit "$work" "$web/work-only.html"
sleep 0.5
history_has only work-only || fail "Work's history lacks its own page"
history_has only home-only || fail "Work's history lacks Home's (Shared) page"
space Home
history_has only home-only || fail "Home's history lacks its own page"
history_has only work-only && fail "Home's history lists Work's page: $(bench spaces history only)"
echo "     Home sees: $(bench spaces history only | jq -c .places)"
ok "4 history: Work's page in Work only, Home's in both"

# 5. ⌥⌘→ / ⌥⌘← through the app.
[ "$(current)" = Home ] || fail "expected Home in front, got $(current)"
bench key "$home" "⌘⌥→" --app >/dev/null
sleep 0.8
[ "$(current)" = Work ] || fail "⌥⌘→ left $(current) in front"
[ "$(front)" = Work ] || fail "after ⌥⌘→ the profile in front is '$(front)'"
bench key "$work" "⌘⌥←" --app >/dev/null
sleep 0.8
[ "$(current)" = Home ] || fail "⌥⌘← left $(current) in front"
[ "$(front)" = "" ] || fail "after ⌥⌘← the profile in front is '$(front)'"
ok "5 ⌥⌘→ / ⌥⌘← switch space and profile"
echo PASS
