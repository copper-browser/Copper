#!/bin/bash
# Page tools (Ardia parity B2): clean links, Copy as Markdown, Copy Link to
# Highlight, the page's Copy Link, Share and Translate Page.
#
#   1. ⇧⌘C copies the address without its trackers; ⌥⇧⌘C as [title](address).
#   2. Copy Link to Highlight copies the address with #:~:text= for the selection.
#   3. WebKit's Copy Link, on a tracked link, copies it clean.
#   4. The menu bar has the items, with their keys.
#   5. Translate Page turns the French page into the Mac's language (code and
#      translate="no" stay) and Show Original puts back every word. It needs the
#      languages on the Mac (System Settings › General › Language & Region ›
#      Translation Languages); without them the run waits on the download
#      prompt and the step says so. TRANSLATE=0 skips it.
#
# A fresh SEARCH_PROBE world, headless, a page server on 127.0.0.1; copies go
# to the world's own pasteboard, so the clipboard of whoever is at the Mac is
# never touched. COPPER_APP=<app> tests that app; otherwise ./build.sh first
# unless COPPER_SKIP_BUILD=1. PT_PORT (MCP, 4602) and PT_WEB (page, 46020).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="pagetools-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
port="${PT_PORT:-4602}"
web="${PT_WEB:-46020}"
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
fail() { echo "FAIL $*"; exit 1; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[int(k)] if isinstance(v,list) else v.get(k,"")
print(v if isinstance(v,str) else json.dumps(v, ensure_ascii=False))' "$1"; }

if [ -z "${COPPER_APP:-}" ] && [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

python3 -m http.server "$web" --bind 127.0.0.1 --directory "$root/docs/fixtures" >/dev/null 2>&1 &
server=$!
defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="$port" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

page="http://127.0.0.1:$web/page-tools-b2.html"
id="$(bench open "$page?id=7&utm_source=newsletter&utm_medium=email&fbclid=IwAR0abc")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null

# 1. ⇧⌘C and ⌥⇧⌘C
out="$(bench page copy address)"
echo "copy address: $(echo "$out" | field url) → $(echo "$out" | field copied)  ($(echo "$out" | field said))"
[ "$(echo "$out" | field copied)" = "$page?id=7" ] || fail "⇧⌘C copied '$(echo "$out" | field copied)'"
out="$(bench page copy markdown)"
echo "copy markdown: $(echo "$out" | field copied)"
[ "$(echo "$out" | field copied)" = "[Le Jardin des Plantes]($page?id=7)" ] || fail "⌥⇧⌘C copied '$(echo "$out" | field copied)'"

# 2. Copy Link to Highlight
bench eval "$id" "var r = document.createRange(); r.selectNodeContents(document.getElementById('quote')); getSelection().removeAllRanges(); getSelection().addRange(r); 1" >/dev/null
out="$(bench page copy highlight)"
link="$(echo "$out" | field copied)"
echo "copy highlight: $link"
case "$link" in "$page?id=7#:~:text=Le%20Jardin%20des%20Plantes%20est%20le%20principal"*) ;; *) fail "highlight link '$link'";; esac

# 3. The page's Copy Link
out="$(bench page linkmenu '#tracked')"
echo "Copy Link (WebKit's, swapped): $(echo "$out" | field copied)"
[ "$(echo "$out" | field copied)" = "https://www.example.com/serres?id=42" ] || fail "Copy Link: $out"

# File › Share…: the picker opens on the clean address (what it offers depends on the Mac).
out="$(bench page share)"
echo "share: shown $(echo "$out" | field shown), offered $(echo "$out" | field offered)"
[ "$(echo "$out" | field shown)" = true ] || fail "Share… showed no picker"
bench page share close >/dev/null

# 4. The menu bar
bench page state | python3 -c '
import json, sys
items = json.load(sys.stdin)["menu"]
for i in items: print("menu: %-6s %-28s %-6s %s" % (i["menu"], i["title"], i["key"], "enabled" if i["enabled"] else "disabled"))
have = {(i["title"], i["key"]) for i in items}
for want in [("Copy Address", "⇧⌘C"), ("Copy as Markdown", "⌥⇧⌘C"), ("Copy Link to Highlight", ""), ("Share…", ""), ("Translate Page", ""), ("Never Translate This Site", "")]:
    if want not in have: sys.exit("FAIL the menu bar has no %s %s" % want)
'

# 5. Translate Page
if [ "${TRANSLATE:-1}" = 1 ]; then
  before="$(bench eval "$id" "document.getElementById('quote').textContent")"
  out="$(bench page translate)"
  echo "translate: $(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("menu",None); print(json.dumps(d, ensure_ascii=False))')"
  state="$(echo "$out" | field state)"
  if [ "$state" = done ]; then
    after="$(bench eval "$id" "document.getElementById('quote').textContent")"
    echo "  quote now: $after"
    [ "$after" != "$before" ] || fail "the quote is still in French"
    [ "$(bench eval "$id" "document.querySelector('code').textContent")" = "jardin.ouvrir()" ] || fail "code was translated"
    [ "$(bench eval "$id" "document.querySelector('[translate=no]').textContent")" = "Muséum national d'Histoire naturelle" ] || fail "translate=no was translated"
    [ "$(bench eval "$id" "document.getElementById('tracked').getAttribute('href')")" = "https://www.example.com/serres?id=42&utm_source=newsletter&utm_medium=email&fbclid=IwAR0abc" ] || fail "a link changed"
    [ -z "${PT_SHOT:-}" ] || { bench shot "$id" "$PT_SHOT" >/dev/null && echo "  picture: $PT_SHOT"; }
    bench page original >/dev/null
    sleep 0.3
    [ "$(bench eval "$id" "document.getElementById('quote').textContent")" = "$before" ] || fail "Show Original did not put the French back"
    echo "ok Translate Page, then Show Original restores the page exactly"
  elif [ "$state" = waiting ]; then
    echo "skip Translate Page: French → this Mac's language isn't installed, the run waits on the download prompt"
    bench page original >/dev/null
  else
    fail "translate ended '$state': $(echo "$out" | field note)"
  fi
fi
echo PASS
