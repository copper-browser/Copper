#!/bin/bash
# AppleScript, Handoff and the Task Manager, end to end (Ardia parity, wave 2).
#
#   1. AppleScript, in Chrome's words, as Raycast and Alfred scripts send it:
#      windows, URL/title of the active tab, make new tab with a URL, set the
#      active tab index, select, close; execute javascript refused until
#      View › Allow JavaScript from Apple Events is on, then answered.
#   2. Handoff: the active tab's address is the current browsing activity, and
#      follows a tab switch; a blank tab offers nothing.
#   3. Task Manager: every loaded tab with its memory and CPU; Sleep puts a
#      background tab to sleep; End Process ends its page's process.
#
# The scripts go through /usr/bin/osascript started by Copper itself (`bench
# script run`), an Apple Event from another process the way Raycast's is. An
# osascript of this shell's over ssh would wait for a consent prompt nobody can
# see. Should that child wait too, the same scripts run in-process (`script
# here`): the same dictionary, objects and commands, and the run says so.
#
# A fresh SEARCH_PROBE world, headless, from a copy of the build under a bundle
# id of its own, so `application id` names this process and no other Copper.
# A local page server, no network. ./build.sh first unless COPPER_SKIP_BUILD=1;
# SHOTS=DIR keeps a picture of the Task Manager there.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="auto-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
bundle_id="com.collinrijock.copper.dev.auto$$"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
tmp="$(cd "$(mktemp -d)" && pwd -P)" # /private/var/…: the path the process runs from, for pgrep
pid="" server=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
  [ -d "$tmp/Copper.app" ] && "$lsregister" -u "$tmp/Copper.app" >/dev/null 2>&1 || true
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist" "$HOME/Library/Preferences/$bundle_id.plist"
  rm -rf "$folder" "$tmp" "$HOME/Library/WebKit/$bundle_id" "$HOME/Library/Caches/$bundle_id" "$HOME/Library/HTTPStorages/$bundle_id" \
    "$HOME/Library/HTTPStorages/$bundle_id.binarycookies"
}
trap cleanup EXIT
trap 'echo "FAIL line $LINENO: $BASH_COMMAND"' ERR
fail() { echo "FAIL $*"; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
built="${COPPER_APP:-$root/build/Copper.app}"
[ -f "$built/Contents/Resources/Copper.sdef" ] || fail "no Copper.sdef in $built"
[ "$(plutil -extract OSAScriptingDefinition raw -o - "$built/Contents/Info.plist")" = Copper.sdef ] || fail "Info.plist names no OSAScriptingDefinition"
app_dir="$tmp/Copper.app"
cp -R "$built" "$app_dir"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --deep -s - "$app_dir" >"$tmp/codesign.log" 2>&1 || fail "re-sign the copy: $(tail -1 "$tmp/codesign.log")"
"$lsregister" -f "$app_dir" >/dev/null 2>&1 || true
app="$app_dir/Contents/MacOS/Copper"

web_port="${AUTO_WEB_PORT:-$((20000 + $$ % 20000))}"
mkdir -p "$tmp/site"
cat >"$tmp/site/one.html" <<'HTML'
<!doctype html><title>One</title><body style="font:16px -apple-system;padding:40px"><h1>One</h1></body>
HTML
cat >"$tmp/site/two.html" <<'HTML'
<!doctype html><title>Two</title><body style="font:16px -apple-system;padding:40px"><h1>Two</h1>
<script>window.answer = 41 + 1</script></body>
HTML
(cd "$tmp/site" && exec python3 -m http.server "$web_port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
site="http://localhost:$web_port"

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# Started by LaunchServices, so Copper answers for itself (macOS's
# "responsible process") and an osascript it starts asks as Copper, not as
# this ssh session.
open -n -g -a "$app_dir" --stdout "$tmp/copper.log" --stderr "$tmp/copper.log" \
  --env SEARCH_PROBE="$world" --env SEARCH_HEADLESS=1 --env SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4614}"
for _ in {1..40}; do pid="$(pgrep -f "^$app" | head -1 || true)"; [ -n "$pid" ] && break; sleep 0.25; done
[ -n "$pid" ] || fail "Copper did not start"
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
curl -fsS "$site/one.html" >/dev/null || fail "page server did not start"

active_url() { bench windows | json 'd["windows"][0]["tabs"][d["windows"][0]["active"]]'; }
tab_count() { bench windows | json 'len(d["windows"][0]["tabs"])'; }

bench windows open 0 "$site/one.html" >/dev/null
for _ in {1..40}; do [ "$(active_url)" = "$site/one.html" ] && break; sleep 0.25; done
[ "$(active_url)" = "$site/one.html" ] || fail "one.html is not the active tab: $(bench windows)"
sleep 1

# 1. AppleScript. `run` (osascript as Copper's child) first; `here` if it can't.
mode=run
probe="$(bench script run "tell application id \"$bundle_id\" to count windows" || true)"
if [ "$(echo "$probe" | json 'd.get("status")' 2>/dev/null)" != 0 ]; then
  echo "note: osascript from Copper could not send (${probe:0:200}); running the scripts in-process"
  mode=here
fi
osa() {
  local reply
  reply="$(bench script "$mode" "tell application id \"$bundle_id\"
$1
end tell")"
  if [ "$mode" = run ]; then
    [ "$(echo "$reply" | json 'd["status"]')" = 0 ] || { echo "ERR $(echo "$reply" | json 'd["err"]')"; return 0; }
    echo "$reply" | json 'd["out"]'
  else
    # The bench leaves out what is null.
    [ "$(echo "$reply" | json 'd.get("message") is None')" = True ] || { echo "ERR $(echo "$reply" | json 'd["message"]') ($(echo "$reply" | json 'd.get("number")'))"; return 0; }
    echo "$reply" | json 'd.get("result", "")'
  fi
}
check() { [ "$2" = "$3" ] || fail "$1: got '$2', wanted '$3'"; echo "ok $1 → $2"; }

check "count windows" "$(osa 'count windows')" 1
check "URL of active tab of front window" "$(osa 'get URL of active tab of front window')" "$site/one.html"
check "title of active tab of front window" "$(osa 'get title of active tab of front window')" "One"
before="$(tab_count)"
made="$(osa "tell front window to make new tab with properties {URL:\"$site/two.html\"}")"
# osascript prints the new tab's reference; in-process, a reference has no text.
[ "$mode" = here ] || case "$made" in *"tab id"*) ;; *) fail "make new tab answered '$made'" ;; esac
for _ in {1..40}; do [ "$(active_url)" = "$site/two.html" ] && break; sleep 0.25; done
check "make new tab with properties {URL:…} → the active tab" "$(active_url)" "$site/two.html"
check "tabs after make" "$(tab_count)" "$((before + 1))"
sleep 1
check "URL of every tab" "$(osa 'get URL of every tab of front window')" "$(bench windows | json '", ".join(d["windows"][0]["tabs"])')"
check "count tabs of front window" "$(osa 'count tabs of front window')" "$((before + 1))"
one_index="$(bench windows | json "d['windows'][0]['tabs'].index('$site/one.html') + 1")"
osa "set active tab index of front window to $one_index" >/dev/null
check "set active tab index" "$(active_url)" "$site/one.html"
check "active tab index" "$(osa 'get active tab index of front window')" "$one_index"
two_index="$(bench windows | json "d['windows'][0]['tabs'].index('$site/two.html') + 1")"
osa "tell tab $two_index of front window to select" >/dev/null
check "tell tab N to select" "$(active_url)" "$site/two.html"

refused="$(osa 'execute active tab of front window javascript "document.title"')"
case "$refused" in ERR*"Allow JavaScript from Apple Events"*) echo "ok execute javascript with the switch off → refused: ${refused:0:110}…" ;; *) fail "execute ran with the switch off: '$refused'" ;; esac
bench script allow on >/dev/null
check "execute javascript \"document.title\"" "$(osa 'execute active tab of front window javascript "document.title"')" "Two"
check "execute javascript \"window.answer\"" "$(osa 'execute active tab of front window javascript "window.answer"')" "42"
bench script allow off >/dev/null

# 2. Handoff follows the active tab (Two now).
for _ in {1..20}; do [ "$(bench handoff | json 'd["url"]')" = "$site/two.html" ] && break; sleep 0.25; done
handoff="$(bench handoff)"
[ "$(echo "$handoff" | json 'd["offered"] and d["type"]')" = NSUserActivityTypeBrowsingWeb ] || fail "Handoff: $handoff"
check "Handoff offers the active tab" "$(echo "$handoff" | json 'd["url"]')" "$site/two.html"
check "Handoff title" "$(echo "$handoff" | json 'd["title"]')" "Two"
osa "set active tab index of front window to $one_index" >/dev/null
for _ in {1..20}; do [ "$(bench handoff | json 'd["url"]')" = "$site/one.html" ] && break; sleep 0.25; done
check "Handoff follows a tab switch" "$(bench handoff | json 'd["url"]')" "$site/one.html"
osa 'tell front window to make new tab' >/dev/null
for _ in {1..20}; do [ "$(bench handoff | json 'd["offered"]')" = False ] && break; sleep 0.25; done
check "a blank tab offers nothing" "$(bench handoff | json 'd["offered"]')" False

# close tab N of front window: the blank one goes.
blank_index="$(osa 'get active tab index of front window')"
count="$(tab_count)"
osa "close tab $blank_index of front window" >/dev/null
check "close tab" "$(tab_count)" "$((count - 1))"

# 3. Task Manager. One in front, Two behind it.
osa "set active tab index of front window to $(bench windows | json "d['windows'][0]['tabs'].index('$site/one.html') + 1")" >/dev/null
check "One in front" "$(active_url)" "$site/one.html"
bench tasks >/dev/null
sleep 2.2
tasks="$(bench tasks)"
echo "tasks: $(echo "$tasks" | json 'd["summary"]'): $(echo "$tasks" | json '"; ".join("%s %s MB %s%% pid %s" % (r["title"], r["mb"], r["cpu"], r["pid"]) for r in d["rows"])')"
[ "$(echo "$tasks" | json 'len(d["rows"]) >= 2 and all(r["mb"] > 0 and r["pid"] > 0 and r["cpu"] is not None for r in d["rows"])')" = True ] \
  || fail "Task Manager rows: $tasks"
echo "ok Task Manager lists every loaded tab with memory, CPU and its process"
bench tasks show >/dev/null
sleep 1
[ "$(bench tasks | json 'd["showing"]')" = True ] || fail "the Task Manager window is not up"
if [ -n "${SHOTS:-}" ]; then bench tasks shot "$SHOTS/task-manager.png" >/dev/null || true; fi
two_id="$(bench tasks | json "[r['id'] for r in d['rows'] if r['title'] == 'Two'][0]")"
bench tasks sleep "$two_id" >/dev/null
for _ in {1..40}; do [ "$(bench tasks | json "any(r['id'] == '$two_id' for r in d['rows'])")" = False ] && break; sleep 0.25; done
tasks="$(bench tasks)"
[ "$(echo "$tasks" | json "any(r['id'] == '$two_id' for r in d['rows'])")" = False ] || fail "Sleep left Two loaded: $tasks"
echo "ok Sleep → Two asleep ($(echo "$tasks" | json 'd["said"]'), $(echo "$tasks" | json 'd["asleep"]') asleep)"
one="$(bench tasks | json "[r for r in d['rows'] if r['title'] == 'One'][0]")"
one_id="$(echo "$one" | python3 -c "import ast,sys; print(ast.literal_eval(sys.stdin.read())['id'])")"
one_pid="$(echo "$one" | python3 -c "import ast,sys; print(ast.literal_eval(sys.stdin.read())['pid'])")"
bench tasks end "$one_id" >/dev/null
for _ in {1..40}; do kill -0 "$one_pid" 2>/dev/null || break; sleep 0.25; done
kill -0 "$one_pid" 2>/dev/null && fail "End Process left pid $one_pid running"
echo "ok End Process → pid $one_pid gone ($(bench tasks | json 'd["said"]'))"
# The active tab whose process ended comes straight back (Dialogs.webViewWebContentProcessDidTerminate).
for _ in {1..40}; do [ "$(bench tasks | json "any(r['title'] == 'One' and r['pid'] != $one_pid for r in d['rows'])")" = True ] && break; sleep 0.25; done
[ "$(bench tasks | json "any(r['title'] == 'One' and r['pid'] != $one_pid for r in d['rows'])")" = True ] || fail "One did not come back: $(bench tasks)"
echo "ok One reloaded in a new process"

echo "PASS automation-e2e ($mode)"
