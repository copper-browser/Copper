#!/bin/bash
# The Accounts popup (⇧⌘Y, the key door) with no real account: a probe world
# whose keychain is a file, and login-frame.html served from 127.0.0.1
# embedding its sign-in from localhost.
#
#   1. Every kept account is listed; the frame's site's account comes first
#      and is the only one marked fillable.
#   2. Search narrows by every word.
#   3. Fill puts the frame's account into the frame; Fill on another site's
#      account is refused and fills nothing.
#   4. Password, name and Open: the probe's own pasteboard gets the secret,
#      the name; Open opens the account's site.
#   5. A picture of the popup, when COPPER_VAULT_SHOT is a path.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="vault-$$"
port="${FIXTURE_PORT:-$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")}"
tmp="$(mktemp -d)"
pid="" server=""
cleanup() {
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  [ -n "$server" ] && { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
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
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT=4233 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

bench passwords add localhost frame@example.invalid frame-secret-1234 >/dev/null
bench passwords add github.com octo@example.invalid gh-secret >/dev/null
bench passwords add bank.example banker@example.invalid bank-secret >/dev/null

tab=$(bench open "http://127.0.0.1:$port/login-frame.html" | grep -oE '[0-9a-f]{8}' | head -1)
bench wait "$tab" 10 >/dev/null
bench select "$tab" >/dev/null 2>&1 || true
sleep 1.5
for _ in {1..20}; do
  bench eval "$tab" 'document.querySelector("iframe").contentWindow.postMessage("focus", "*"); 1' >/dev/null 2>&1 || true
  sleep 0.5
  [ "$(bench bw rows | jq -r .host)" = localhost ] && break
done

# 1. Everything, this frame's site first.
rows=$(bench bw vault rows)
echo "   vault: $(jq -c '[.rows[] | [.label, .user, .fills]]' <<<"$rows")"
[ "$(jq '.rows | length' <<<"$rows")" = 3 ] || fail "the popup lists $(jq '.rows | length' <<<"$rows") accounts, not 3"
[ "$(jq -r '.rows[0].user' <<<"$rows")" = frame@example.invalid ] || fail "this frame's account isn't first"
[ "$(jq '[.rows[] | select(.fills)] | length' <<<"$rows")" = 1 ] || fail "more than this frame's account is fillable"
echo "ok every account is listed, the frame's site's first and the only fillable one"

# 2. Search.
[ "$(bench bw vault rows octo github | jq -r '[.rows[].user] | join(",")')" = octo@example.invalid ] || fail "search 'octo github' didn't narrow to one"
[ "$(bench bw vault rows nothing-here | jq '.rows | length')" = 0 ] || fail "a search for nothing found something"
echo "ok search narrows by every word"

# 3. Fill: the frame's account goes in; another site's is refused.
bench bw vault act 1 fill >/dev/null   # bank.example — not this frame's
sleep 1
grep -q 'nothing yet' <<<"$(bench eval "$tab" 'document.getElementById("said").textContent')" || fail "another site's account was filled into the frame"
bench bw vault act 0 fill >/dev/null
said=""
for _ in {1..20}; do
  said=$(bench eval "$tab" 'document.getElementById("said").textContent')
  grep -q 'frame@example.invalid' <<<"$said" && break
  sleep 0.25
done
grep -q '"user":"frame@example.invalid","passwordLength":17' <<<"$said" || fail "Fill didn't fill the frame (it says $said)"
echo "ok Fill puts this site's account into the frame; another site's is refused"

# 4. Copy and open.
bench bw vault act 2 password >/dev/null; sleep 1   # sorted: localhost, bank.example, github.com
[ "$(bench ai clipboard | jq -r .text)" = gh-secret ] || fail "Password didn't copy github.com's password"
bench bw vault act 1 user >/dev/null; sleep 0.5
[ "$(bench ai clipboard | jq -r .text)" = banker@example.invalid ] || fail "Name didn't copy the username"
bench bw vault act 2 open >/dev/null; sleep 1
bench tabs | grep -q 'github.com' || fail "Open didn't open github.com"
echo "ok Password and Name copy, Open opens the account's site"

# 5. The popup, drawn.
if [ -n "${COPPER_VAULT_SHOT:-}" ]; then
  bench select "$tab" >/dev/null 2>&1 || true
  bench bw vault open >/dev/null; sleep 2
  bench canvas picture "$COPPER_VAULT_SHOT" >/dev/null && echo "ok drew the window with the popup to $COPPER_VAULT_SHOT"
fi
echo "ok vault popup e2e"
