#!/bin/bash
# Extension pages that open the web, and the tabs extensions see — the two
# things 1Password's Start setup tripped over. A tiny MV3 extension
# (docs/fixtures/extension-tabs/), a local page server, a headless Copper
# and a fresh SEARCH_PROBE world; no network, no real Copper world touched.
#
#   1. tabs.create from the popup opens a tab (it always did — the control).
#   2. The popup sending itself to a web address (window.location.href, what
#      1Password's Sign in does) opens that address in a tab.
#   3. The extension's page in a tab doing the same becomes that page.
#   4. window.open from the extension's page gets a tab that loads.
#   5. A page in a space not on screen still has a tab: its content script's
#      runtime.sendMessage answers instead of failing "Tab not found".
#   6. The content script's import() of a web-accessible module works in
#      every frame it ran in, and nothing landed in the extension's errors.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="exttabs-$$"
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

# The pages: a web page to open, and one that reloads itself every second
# (its content script runs again while its space is off screen).
mkdir -p "$tmp/site"
printf '<!doctype html><title>target</title><p>target</p>\n' >"$tmp/site/target.html"
printf '<!doctype html><meta http-equiv="refresh" content="1"><title>refresh</title><p>refresh</p>\n' >"$tmp/site/refresh.html"
port=$((20000 + $$ % 20000))
(cd "$tmp/site" && exec uvx --quiet python -m http.server "$port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -sf "http://127.0.0.1:$port/target.html" >/dev/null 2>&1 && break; sleep 0.25; done
curl -sf "http://127.0.0.1:$port/target.html" >/dev/null || fail "local page server did not start"
web="http://localhost:$port"

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

# A copy, so the install never writes into the repository.
cp -R "$root/docs/fixtures/extension-tabs" "$tmp/extension"
bench ext-folder "$tmp/extension" --yes >/dev/null
ext=""
for _ in {1..40}; do
  ext=$(bench extensions | jq -r '.extensions[] | select(.name == "Copper extension-tabs fixture" and .loaded) | .id')
  [ -n "$ext" ] && break; sleep 0.25
done
[ -n "$ext" ] || fail "fixture extension did not load"
echo "ok fixture loaded as $ext"

# Waits until a tab at this address (a prefix) is listed, loaded.
await_tab() {
  local want="$1"
  for _ in {1..40}; do
    if bench tabs | grep -F -- "$want" >/dev/null; then return 0; fi
    sleep 0.25
  done
  return 1
}
# The id of the tab at this address.
tab_at() { bench tabs | grep -F -- "$1" | tail -1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{8}$/) { print $i; exit } }'; }
# What a promise in the extension's page resolves to, as JSON.
ask() {
  local tab="$1" js="$2"
  bench eval "$tab" "window.__answer = undefined; Promise.resolve().then(() => $js).then((v) => { window.__answer = JSON.stringify(v); }, (e) => { window.__answer = JSON.stringify({ error: String(e && e.message || e) }); }); 1" >/dev/null
  for _ in {1..40}; do
    local got; got=$(bench eval "$tab" 'window.__answer === undefined ? "" : window.__answer' 2>/dev/null || true)
    if [ -n "$got" ]; then echo "$got"; return 0; fi
    sleep 0.25
  done
  return 1
}

# 1. tabs.create from the popup.
bench ext-press "$ext" >/dev/null
for _ in {1..40}; do bench ext-popup "$ext" 'document.readyState' >/dev/null 2>&1 && break; sleep 0.25; done
bench ext-popup "$ext" "location.search = '?to=' + encodeURIComponent('$web/target.html?via=create'); 1" >/dev/null
sleep 1
bench ext-popup "$ext" 'document.getElementById("create").click(); 1' >/dev/null
await_tab "$web/target.html?via=create" || fail "tabs.create from the popup opened no tab"
echo "ok tabs.create from the popup opens a tab"

# 2. The popup sending itself to the web (1Password's Sign in).
bench ext-press "$ext" >/dev/null
for _ in {1..40}; do bench ext-popup "$ext" 'document.readyState' >/dev/null 2>&1 && break; sleep 0.25; done
bench ext-popup "$ext" "location.search = '?to=' + encodeURIComponent('$web/target.html?via=popup-navigate'); 1" >/dev/null
sleep 1
bench ext-popup "$ext" 'document.getElementById("navigate").click(); 1' >/dev/null
await_tab "$web/target.html?via=popup-navigate" || fail "the popup's window.location.href to a web address went nowhere"
if bench ext-popup "$ext" '1' >/dev/null 2>&1; then fail "the popup stayed open after handing its address to a tab"; fi
echo "ok the popup's window.location.href opens the address in a tab and closes"

# 3. The extension's page in a tab doing the same.
page=$(bench ext-page "$ext" page.html)
await_tab "chrome-extension://$ext/page.html" || fail "the extension's page did not open"
sleep 1
bench eval "$page" "location.search = '?to=' + encodeURIComponent('$web/target.html?via=page-navigate'); 1" >/dev/null
sleep 1
bench eval "$page" 'document.getElementById("navigate").click(); 1' >/dev/null
await_tab "$web/target.html?via=page-navigate" || fail "the extension's page in a tab could not go to a web address"
id=$(tab_at "$web/target.html?via=page-navigate")
title=""
for _ in {1..40}; do title=$(bench eval "$id" 'document.title' 2>/dev/null || true); [ "$title" = target ] && break; sleep 0.25; done
[ "$title" = target ] || fail "the tab the extension's page became never loaded (title “$title”)"
echo "ok the extension's page in a tab becomes the web page it went to"

# 4. window.open from the extension's page.
page=$(bench ext-page "$ext" page.html)
await_tab "chrome-extension://$ext/page.html" || fail "the extension's page did not open again"
sleep 1
bench eval "$page" "window.open('$web/target.html?via=window-open'); 1" >/dev/null
await_tab "$web/target.html?via=window-open" || fail "window.open from the extension's page opened no tab"
id=$(tab_at "$web/target.html?via=window-open")
title=""
for _ in {1..40}; do title=$(bench eval "$id" 'document.title' 2>/dev/null || true); [ "$title" = target ] && break; sleep 0.25; done
[ "$title" = target ] || fail "window.open's tab stayed blank (title “$title”)"
echo "ok window.open from the extension's page opens a tab that loads"

# 5. A page reloading in a space that is not on screen.
bench open "$web/refresh.html" >/dev/null
await_tab "$web/refresh.html" || fail "the reloading page did not open"
sleep 1.5
bench spaces new Elsewhere >/dev/null
sleep 4
bench spaces select 0 >/dev/null
sleep 1
page=$(bench ext-page "$ext" page.html)
await_tab "chrome-extension://$ext/page.html" || fail "the extension's page did not open for the checks"
sleep 1
seen=$(ask "$page" 'chrome.runtime.sendMessage({ kind: "seen" })') || fail "the worker did not answer"
stored=$(ask "$page" 'chrome.storage.local.get(null).then((s) => Object.values(s))') || fail "storage did not answer"
ran=$(jq --arg u "$web/refresh.html" '[.[] | select(.url == $u)] | length' <<<"$stored")
told=$(jq --arg u "$web/refresh.html" '[.[] | select(.url == $u)] | length' <<<"$seen")
[ "$ran" -ge 4 ] || fail "the reloading page's content script ran only $ran times"
# Every run reached the worker, off screen or not (a run or two may still be
# on its way when the worker is asked).
[ "$told" -ge $((ran - 2)) ] || fail "only $told of $ran content-script runs reached the worker — a tab in another space is unknown to WebKit"
echo "ok a page in a space off screen still reaches the worker ($told of $ran runs)"

# 6. import() in every frame, and no errors.
broken=$(jq -c '[.[] | select(.ok != true)]' <<<"$stored")
[ "$broken" = "[]" ] || fail "the content script's import() failed: $broken"
errors=$(bench extensions | jq -c --arg id "$ext" '.extensions[] | select(.id == $id) | .errors')
[ "$errors" = "[]" ] || fail "the extension recorded errors: $errors"
echo "ok import() worked in all $(jq length <<<"$stored") frames and no errors were recorded"
echo "ok extension tabs e2e"
