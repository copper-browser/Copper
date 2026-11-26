#!/bin/bash
# Ardia parity, shortcut rebinding, end to end in a headless probe world.
#
#   1. One table: the menu bar carries every default (⌘D Duplicate Tab, and
#      wave 1's ⌥⌘N Little Copper, ⇧⌘D Split View, ⌥⇧⌘C Copy as Markdown).
#   2. Settings › Shortcuts records a new key: `shortcuts record duplicateTab`,
#      then ⌥⌘U pressed through the app's key monitor is the row's. The menu
#      bar's Duplicate Tab says ⌥⌘U, and the settings file has it.
#   3. ⌥⌘U on the page duplicates the tab; ⌘D no longer does.
#   4. A key another command holds asks first: ⌘E for Reload → Cancel keeps
#      both; recorded again and Replace moves it (Agent has none), and ⌘E
#      reloads the page.
#   5. A command only the menu runs (New Little Copper Window) on a new key,
#      fired through the menu bar with it; the old key does nothing.
#   6. A relaunch keeps the keys; Reset puts one back; Reset All all.
#   7. Settings' index check passes with the new page, and search finds a
#      command on it.
#
# A fresh SEARCH_PROBE world, headless; no network. Port SEARCH_MCP_PORT
# (default 4613). ./build.sh first unless COPPER_SKIP_BUILD=1. Pictures of
# the page go to $SHOTS when set.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="shortcuts-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
tmp="$(mktemp -d)"
pid=""
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

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4613}" "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return 0; sleep 0.5; done
  fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
key_of() { bench shortcuts | jq -r --arg id "$1" '.commands[] | select(.id == $id) | .key'; }
menu_key() { bench shortcuts menu | jq -r --arg t "$1" '.menu[$t] // ""'; }
note() { bench shortcuts | jq -r '.note.text // ""'; }
tabs() { bench tabs | wc -l | tr -d ' '; }
press() { bench key "$id" "$1" --app >/dev/null; sleep 0.4; }
shot() { [ -n "${SHOTS:-}" ] && bench shortcuts picture "$SHOTS/$1.png" ${2:-} >/dev/null && echo "     picture $SHOTS/$1.png" || true; }

launch
sleep 1
id="$(bench open "file://$root/docs/fixtures/keys.html")"
bench wait "$id" 10 >/dev/null
bench select "$id" >/dev/null

# 1. Every default, from the table, on the menu bar.
for pair in "Duplicate Tab=⌘D" "New Little Copper Window=⌥⌘N" "Split View=⇧⌘D" "Copy as Markdown=⌥⇧⌘C" "Clean Up Tabs=⌥⌘K" "New Tab=⌘T" "Previous Space=⌃⌥←" "Zoom In=⌘+"; do
  title="${pair%%=*}"; want="${pair#*=}"
  [ "$(menu_key "$title")" = "$want" ] || fail "menu bar: $title is '$(menu_key "$title")', not $want"
done
total=$(bench shortcuts | jq '.commands | length')
ok "the menu bar carries the table's keys ($total commands; ⌥⌘N Little, ⇧⌘D Split, ⌥⇧⌘C Markdown among them)"
shot shortcuts-page

# 2. Settings › Shortcuts records ⌥⌘U for Duplicate Tab.
bench settings open shortcuts >/dev/null
sleep 0.6
n0=$(tabs)
bench shortcuts record duplicateTab >/dev/null
[ "$(bench shortcuts | jq -r .recording)" = duplicateTab ] || fail "the row is not recording"
press "⌥⌘u"
[ "$(key_of duplicateTab)" = "⌥⌘U" ] || fail "recorded key: '$(key_of duplicateTab)' (state: $(bench shortcuts | jq -c '{recording, note, overrides}'))"
[ "$(bench shortcuts | jq -r .recording)" = null ] || fail "still recording after a key"
[ "$(tabs)" = "$n0" ] || fail "the key the row recorded also ran a command"
sleep 0.5
[ "$(menu_key "Duplicate Tab")" = "⌥⌘U" ] || fail "menu bar's Duplicate Tab is '$(menu_key "Duplicate Tab")' after the rebinding"
defaults read "$domain" shortcuts | tee "$tmp/stored.txt" | grep -q 'duplicateTab = "\\U2325\\U2318U"\|duplicateTab = "⌥⌘U"' \
  || fail "not in the settings file: $(cat "$tmp/stored.txt")"
ok "recorded ⌥⌘U on Duplicate Tab: the menu bar says ⌥⌘U, the settings file keeps it"
bench settings close >/dev/null

# 3. The new key duplicates; the old one doesn't.
bench select "$id" >/dev/null
n1=$(tabs); press "⌥⌘u"; n2=$(tabs)
[ "$n2" = $((n1 + 1)) ] || fail "⌥⌘U did not duplicate the tab ($n1 → $n2)"
bench select "$id" >/dev/null
press "⌘d"; n3=$(tabs)
[ "$n3" = "$n2" ] || fail "⌘D still duplicates ($n2 → $n3)"
ok "⌥⌘U duplicates the tab ($n1 → $n2); ⌘D does nothing now ($n3)"

# 4. ⌘E is Agent's: asked, cancelled, then replaced.
bench shortcuts set reload ⌘E >/dev/null
echo "     note: $(note)"
note | grep -q "Agent" || fail "no question about Agent's ⌘E: $(bench shortcuts | jq -c .note)"
[ "$(key_of reload)" = "⌘R" ] && [ "$(key_of agent)" = "⌘E" ] || fail "an unanswered question moved a key"
shot shortcuts-conflict
bench shortcuts cancel >/dev/null
[ -z "$(note)" ] && [ "$(key_of reload)" = "⌘R" ] && [ "$(key_of agent)" = "⌘E" ] || fail "Cancel changed something"
ok "⌘E for Reload asks first (Agent holds it); Cancel keeps both"
bench shortcuts record reload >/dev/null
press "⌘e"
note | grep -q "Agent" || fail "recording ⌘E did not ask: $(bench shortcuts | jq -c .note)"
bench shortcuts replace >/dev/null
[ "$(key_of reload)" = "⌘E" ] && [ -z "$(key_of agent)" ] || fail "Replace: reload '$(key_of reload)', agent '$(key_of agent)'"
sleep 0.5
[ "$(menu_key "Reload Page")" = "⌘E" ] || fail "menu bar's Reload Page is '$(menu_key "Reload Page")'"
bench select "$id" >/dev/null
bench eval "$id" 'window.marker = 7; 7' >/dev/null
press "⌘e"; bench wait "$id" 10 >/dev/null; sleep 0.5
[ "$(bench eval "$id" 'String(window.marker || 0)')" = 0 ] || fail "⌘E did not reload the page"
ok "Replace moved ⌘E to Reload (Agent has no key), and ⌘E reloads the page"

# 5. A command only the menu runs, on a new key, through the menu bar.
bench shortcuts set newLittle ⌃⌥L >/dev/null
[ "$(key_of newLittle)" = "⌃⌥L" ] || fail "newLittle: '$(key_of newLittle)'"
sleep 0.5
[ "$(menu_key "New Little Copper Window")" = "⌃⌥L" ] || fail "menu: '$(menu_key "New Little Copper Window")'"
l0=$(bench little | jq '.littles | length')
old=$(bench shortcuts press ⌥⌘N | jq -r .menuTook)
new=$(bench shortcuts press ⌃⌥L | jq -r .menuTook)
sleep 1
l1=$(bench little | jq '.littles | length')
[ "$old" = false ] || fail "the menu bar still takes ⌥⌘N"
[ "$new" = true ] && [ "$l1" = $((l0 + 1)) ] || fail "⌃⌥L through the menu bar: took $new, Little Coppers $l0 → $l1"
ok "Little Copper on ⌃⌥L: the menu bar opens one with it ($l0 → $l1), ⌥⌘N is free"
bench little close >/dev/null 2>&1 || true

# 6. A relaunch keeps them; Reset; Reset All.
bench windows quit >/dev/null 2>&1 || true
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
stop
launch; sleep 1
[ "$(key_of duplicateTab)" = "⌥⌘U" ] && [ "$(key_of reload)" = "⌘E" ] && [ "$(key_of newLittle)" = "⌃⌥L" ] \
  || fail "after relaunch: $(bench shortcuts | jq -c .overrides)"
[ "$(menu_key "Duplicate Tab")" = "⌥⌘U" ] || fail "menu after relaunch: '$(menu_key "Duplicate Tab")'"
ok "a relaunch keeps ⌥⌘U, ⌘E and ⌃⌥L"
bench shortcuts reset agent >/dev/null
note | grep -q "Reload" || fail "resetting Agent did not ask about Reload's ⌘E"
bench shortcuts replace >/dev/null
[ "$(key_of agent)" = "⌘E" ] && [ -z "$(key_of reload)" ] || fail "reset agent: agent '$(key_of agent)', reload '$(key_of reload)'"
ok "Reset Agent asks for ⌘E back from Reload, then takes it"
bench shortcuts reset all >/dev/null
[ "$(bench shortcuts | jq '.overrides | length')" = 0 ] && [ "$(key_of duplicateTab)" = "⌘D" ] && [ "$(key_of reload)" = "⌘R" ] \
  || fail "Reset All: $(bench shortcuts | jq -c .overrides)"
defaults read "$domain" shortcuts >/dev/null 2>&1 && fail "Reset All left shortcuts in the settings file"
sleep 0.5
[ "$(menu_key "Duplicate Tab")" = "⌘D" ] && [ "$(menu_key "New Little Copper Window")" = "⌥⌘N" ] || fail "menu after Reset All"
ok "Reset All: every default back, on the menu bar too, nothing kept"

# 7. Settings' index and search.
check="$(bench settings index check)"
[ "$(jq -r .ok <<<"$check")" = true ] || fail "settings index check: $(jq -c .failures <<<"$check")"
top=$(bench settings search "duplicate tab" | jq -r '.results[0] | "\(.page) \(.title)"')
[ "$top" = "shortcuts Duplicate Tab" ] || fail "search 'duplicate tab' → $top"
ok "settings index check passes; search 'duplicate tab' → Shortcuts › Duplicate Tab"
shot shortcuts-page-dark dark
echo "PASS shortcuts-e2e"
