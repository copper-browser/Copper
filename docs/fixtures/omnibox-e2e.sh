#!/bin/bash
# The field's words (Fork/SearchEngines.swift), end to end in a headless probe:
#
#   1. ⌘L: "2*21" Return copies 42; "!w paris" Return goes to Wikipedia.
#   2. ⌘T "2*21" leads with "2*21 = 42", and Return copies 42.
#   3. ⌘T "!w paris" searches Wikipedia; "paris !w" too.
#   4. ⌘T "doc.new" and "new sheet" open the Google .new shortcuts.
#   5. ⌘T "yt", Tab, "cats" searches YouTube.
#   6. None of 2–5 asked anyone for completions ("cats" alone does, once).
#   7. Settings' engine: DuckDuckGo words go to DuckDuckGo, ⌘K's too.
#   8. Settings search finds the engine row.
#   9. Search suggestions off: typing in ⌘L, ⌘K and ⌘T asks no engine anything.
#
# A fresh SEARCH_PROBE world; ./build.sh first unless COPPER_SKIP_BUILD=1.
# SHOTS=DIR keeps pictures of the card and Settings; TRACES=1 prints typing traces.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="omnibox-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
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
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4603}" "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
  bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
launch

# FIELD of the row ⌘T would take for TEXT (more bench flags after it).
card() { bench newtab "$@" --json >"$tmp/card.json"; }
picked() {
  python3 - "$tmp/card.json" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
rows = {r["index"]: r for g in d["groups"] for r in g["rows"]}
print(rows.get(d["picked"], {}).get(sys.argv[2], ""))
EOF
}
# What Copper copied: the probe world's own pasteboard, never the Mac's.
clip() { "$root/bench" --world "$world" ai clipboard | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])'; }
asks() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["suggestAsks"])' "$tmp/card.json"; }

# 1. ⌘L, the address field over a page (first: a fresh window, as key-beep-e2e.sh has it).
id="$(bench open "file://$root/docs/fixtures/keys.html")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
# ⌘L, then typing once the field is up (as key-beep-e2e.sh waits).
field() {
  bench key "$id" "⌘l" --app >/dev/null
  for _ in {1..20}; do bench probe | grep -q '"field": true' && return; sleep 0.25; done
  fail "⌘L did not open the field: $(bench probe | grep -E '"field"|"typed"')"
}
field
bench key "$id" "2*21" --app >/dev/null
bench probe | grep -q '"typed": "2\*21"' || fail "⌘L: typing did not reach the field ($(bench probe | grep '"typed"'); first responder $(bench key "$id" "" --app | grep -m1 firstResponder))"
bench key "$id" "↩" --app >/dev/null
[ "$(clip)" = 42 ] || fail "⌘L 2*21 Return left '$(clip)' on the clipboard"
field
bench key "$id" "!w paris" --app >/dev/null
bench probe | grep -q '"typed": "!w paris"' || fail "⌘L: '!w paris' did not reach the field ($(bench probe | grep '"typed"'))"
bench key "$id" "↩" --app >"$tmp/return.json"
went=""
for _ in {1..20}; do bench tabs >"$tmp/tabs.txt"; grep -q "wikipedia.org" "$tmp/tabs.txt" && { went=1; break; }; sleep 0.5; done
[ -n "$went" ] || fail "⌘L !w paris ↩ did not go to Wikipedia: tabs $(tr '\n' ' ' <"$tmp/tabs.txt"); after ↩ $(tr -d '\n ' <"$tmp/return.json"); probe $(bench probe | grep -E '"typed"|"field"' | tr -d '\n ')"
echo "ok 1 ⌘L 2*21 ↩ copied 42; !w paris ↩ went to Wikipedia"

# 2. A sum.
card "2*21"
[ "$(picked key)" = "2*21 = 42" ] || fail "2*21: the row Return takes is '$(picked key)'"
[ "$(picked hint)" = "Copy" ] || fail "2*21: its hint is '$(picked hint)'"
start="$(asks)"
bench page copy address >/dev/null # the tab's address over step 1's 42, so the 42 below is ⌘T's
[ "$(clip)" != 42 ] || fail "bench page copy did not replace the clipboard"
card "2*21" --go
[ "$(clip)" = 42 ] || fail "Return on 2*21 left '$(clip)' on the clipboard"
echo "ok 2 ⌘T 2*21 → $(picked key), Return copied $(clip)"

# 3. !bangs, first word or last.
card "!w paris"
[ "$(picked url)" = "https://en.wikipedia.org/wiki/Special:Search?search=paris" ] || fail "!w paris → '$(picked url)'"
[ "$(picked key)" = "Search Wikipedia for “paris”" ] || fail "!w paris says '$(picked key)'"
card "paris !w"
[ "$(picked url)" = "https://en.wikipedia.org/wiki/Special:Search?search=paris" ] || fail "paris !w → '$(picked url)'"
card "!zzqqx cats"
[ "$(picked url)" = "https://duckduckgo.com/?q=%21zzqqx%20cats" ] || fail "an unknown bang → '$(picked url)'"
echo "ok 3 ⌘T !w paris → $(card "!w paris"; picked url)"

# 4. .new
card "doc.new"
[ "$(picked key)" = "New Google Doc" ] && [ "$(picked url)" = "https://docs.new" ] || fail "doc.new → '$(picked key)' $(picked url)"
card "new sheet"
[ "$(picked url)" = "https://sheets.new" ] || fail "new sheet → '$(picked url)'"
echo "ok 4 ⌘T doc.new → New Google Doc (https://docs.new), new sheet → https://sheets.new"

# 5. Site search: yt, Tab, cats.
card "yt" --keys "⇥cats"
[ "$(picked key)" = "Search YouTube for “cats”" ] || fail "yt⇥cats: the row is '$(picked key)'"
[ "$(picked url)" = "https://www.youtube.com/results?search_query=cats" ] || fail "yt⇥cats → '$(picked url)'"
typed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keys"][-1]["typed"])' "$tmp/card.json")"
[ "$typed" = "!yt cats" ] || fail "yt⇥cats left '$typed' in the field"
via="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["keysVia"])' "$tmp/card.json")"
echo "ok 5 ⌘T yt⇥cats (keys via $via) → field '$typed', row $(picked url)"

# 6. Nothing was asked for any of it.
[ "$(asks)" = "$start" ] || fail "completions were asked for: $start → $(asks)"
card "cats" --settle 1.2
[ "$(asks)" = $((start + 1)) ] || fail "the control ('cats') asked $(( $(asks) - start )) times, not once"
echo "ok 6 no completion asks for 2*21, !w paris, doc.new, yt⇥cats (the 'cats' control asked once)"

# Typing traces (TRACES=1): ⌘T, a letter every 80 ms, the main thread's busy time.
if [ -n "${TRACES:-}" ]; then
  for text in "2*21" "!w paris" "doc.new" "yt" "cats"; do
    echo "--- trace: $text"; bench newtab "$text" --type
  done
  echo "--- settings index check"; bench settings index check | head -12 || true
fi

# 7. Another engine.
kill "$pid"
wait "$pid" 2>/dev/null || true
defaults write "$domain" search.engine duckduckgo
launch
[ "$(bench settings browse prefs | python3 -c 'import json,sys; print(json.load(sys.stdin)["searchEngine"])')" = duckduckgo ] || fail "the engine did not change"
card "copper browser"
[ "$(picked url)" = "https://duckduckgo.com/?q=copper%20browser" ] || fail "DuckDuckGo: ⌘T's search row → '$(picked url)'"
bench bar "copper browser" >"$tmp/bar.txt"
grep -q "Search DuckDuckGo for “copper browser”" "$tmp/bar.txt" || fail "⌘K: $(tail -3 "$tmp/bar.txt")"
echo "ok 7 DuckDuckGo picked: ⌘T and ⌘K search it"

# 8. Settings search.
bench settings search "duckduckgo" --table | head -1 | grep -q "general" || fail "Settings search: $(bench settings search duckduckgo --table | head -2)"
echo "ok 8 Settings search 'duckduckgo' → $(bench settings search "duckduckgo" --table | head -1 | tr -s ' ')"

# 9. Search suggestions off (DuckDuckGo, which has them, still picked).
kill "$pid"
wait "$pid" 2>/dev/null || true
defaults write "$domain" search.suggest -bool false
launch
[ "$(bench settings browse prefs | python3 -c 'import json,sys; print(json.load(sys.stdin)["searchSuggestions"])')" = False ] || fail "the switch did not turn off"
id="$(bench open "file://$root/docs/fixtures/keys.html")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null
field
bench key "$id" "copper browser" --app >/dev/null
sleep 1
bench key "$id" "⎋" --app >/dev/null
bench bar "copper browser" >/dev/null
for text in "c" "ca" "cats" "copper browser" "what is my ip"; do card "$text" --settle 1.2; done
[ "$(asks)" = 0 ] || fail "with suggestions off, $(asks) completions were asked for"
[ "$(picked url)" = "https://duckduckgo.com/?q=what%20is%20my%20ip" ] || fail "with suggestions off, the search row → '$(picked url)'"
bench settings search "search suggestions" --table | head -1 | grep -q "general" || fail "Settings search: $(bench settings search "search suggestions" --table | head -2)"
echo "ok 9 suggestions off: ⌘L, ⌘K and ⌘T typing asked $(asks) times; the search row still searches DuckDuckGo"

if [ -n "${SHOTS:-}" ]; then
  mkdir -p "$SHOTS"
  for text in "2*21" "!w paris" "doc.new"; do
    bench newtab "$text" --keep >/dev/null; sleep 0.6
    bench canvas picture "$SHOTS/card-$(printf '%s' "$text" | tr -c 'a-z0-9' '-').png" >/dev/null
  done
  bench newtab "yt" --keys "⇥cats" --keep >/dev/null; sleep 0.6
  bench canvas picture "$SHOTS/card-yt-tab-cats.png" >/dev/null
  bench settings browse picture search "$SHOTS/settings-search.png" 560 light >/dev/null
  defaults write "$domain" search.engine custom
  bench settings browse picture search "$SHOTS/settings-search-custom.png" 560 dark >/dev/null
fi
echo PASS
