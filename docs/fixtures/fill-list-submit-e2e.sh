#!/bin/bash
# The accounts list hanging from a sign-in box goes away once the sign-in is
# sent or its box leaves the page — it used to stay over "Signed in."
# (council r3 B6). Probe world with a file keychain, login.html from
# 127.0.0.1.
#
#   1. Focus in the email box hangs the list.
#   2. The form taken out of the page (a sign-in done in place, no focusout)
#      takes the list with it.
#   3. A sign-in sent with the caret still in a box that stays (submit, form
#      kept) takes the list too.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="filllist-$$"
port="${FIXTURE_PORT:-$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")}"
tmp="$(mktemp -d)"
pid="" server=""
cleanup() {
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  [ -n "$server" ] && kill "$server" 2>/dev/null || true
  defaults delete "com.collinrijock.copper.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.collinrijock.copper.test.$world.plist"
  rm -rf "$HOME/Library/Application Support/Copper ($world)" "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

(cd "$root/docs/fixtures" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/http.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -fsS -o /dev/null 2>/dev/null "http://127.0.0.1:$port/login.html" && break; sleep 0.25; done
defaults write "com.collinrijock.copper.test.$world" bench -bool true
defaults write "com.collinrijock.copper.test.$world" welcomed -bool true
defaults write "com.collinrijock.copper.test.$world" probe.keychain -string file
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
bench passwords add 127.0.0.1 page@example.invalid page-secret >/dev/null

count() { bench bw rows | jq '.rows | length'; }
# The list up from the email box, on a fresh copy of the page.
hang() {
  local tab
  tab=$(bench open "http://127.0.0.1:$port/login.html" | grep -oE '[0-9a-f]{8}' | head -1)
  [ -n "$tab" ] || fail "no tab"
  bench wait "$tab" 10 >/dev/null
  bench select "$tab" >/dev/null 2>&1 || true
  sleep 1
  [ -n "${1:-}" ] && bench eval "$tab" "$1" >/dev/null
  for _ in {1..20}; do
    bench eval "$tab" 'document.getElementById("username").focus(); 1' >/dev/null
    sleep 0.5
    [ "$(count)" -gt 0 ] && break
  done
  [ "$(count)" -gt 0 ] || fail "no list hung from the email box"
  echo "$tab"
}
gone() {
  for _ in {1..12}; do [ "$(count)" = 0 ] && return 0; sleep 0.25; done
  return 1
}

tab=$(hang)
echo "ok focus in the email box hangs the list"

bench eval "$tab" 'document.getElementById("login").remove(); 1' >/dev/null
gone || fail "the list stayed after its box left the page ($(bench bw rows | jq -c .))"
echo "ok the form taken out of the page takes the list with it"

# A form that stays after it is sent (the page's own handler swapped for one
# that keeps it), the caret still in its email box.
keep='const f = document.getElementById("login"), c = f.cloneNode(true); f.replaceWith(c); c.addEventListener("submit", e => e.preventDefault()); 1'
tab=$(hang "$keep")
bench eval "$tab" 'document.getElementById("username").value = "page@example.invalid"; document.getElementById("password").value = "page-secret"; document.getElementById("login").requestSubmit(); 1' >/dev/null
gone || fail "the list stayed after the sign-in was sent ($(bench bw rows | jq -c .))"
[ "$(bench eval "$tab" 'document.activeElement && document.activeElement.id')" = '"username"' ] \
  || [ "$(bench eval "$tab" 'document.activeElement && document.activeElement.id')" = 'username' ] \
  || echo "   (note: the caret left the box on submit: $(bench eval "$tab" 'document.activeElement && document.activeElement.id'))"
echo "ok sending the sign-in takes the list with it"
echo "ok fill list submit e2e"
