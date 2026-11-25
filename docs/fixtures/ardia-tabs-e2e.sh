#!/bin/bash
# Ardia parity, tab organisation, end to end in a headless probe world.
#
#   1. A Today row dragged by real mouse events onto the middle of a loose
#      Saved row makes a new folder of the two, named by their shared site
#      ("Google"), and the drop is written to the session.
#   2. The launch's own Today sweep puts the two stale rows in Recently
#      Cleaned; ⌥⌘K's Clean Up (`sections cleanup`) adds a row aged past the
#      window; a row comes back with `sections restore ID`, the rest with
#      `restore all`; Clear (⇧⌘K) also fills it and its Undo empties it.
#   3. Recently Cleaned survives a relaunch (cleaned.json).
#
# A fresh SEARCH_PROBE world; the rows stay asleep, so nothing loads. Port
# SEARCH_MCP_PORT (default 4606). ./build.sh first unless COPPER_SKIP_BUILD=1.
# Pictures of the column go to $SHOTS when set.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="ardiatabs-$$"
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

A=AAAAAAAA-0000-4000-8000-000000000001
now=$(date +%s); old=$((now - 30 * 3600))
mkdir -p "$folder"
cat >"$folder/session.json" <<JSON
{"active":2,"space":"$A","pins":[],
 "spaces":[{"id":"$A","name":"Alpha","hue":0.1}],
 "tabs":[
  {"url":"https://mail.google.com/mail/u/0/","title":"Inbox","space":"$A","saved":true,"seen":$now},
  {"url":"https://github.com/copper-browser/Copper","title":"Copper repo","space":"$A","saved":true,"seen":$now},
  {"url":"https://calendar.google.com/calendar/r","title":"Calendar","space":"$A","saved":false,"seen":$now},
  {"url":"https://news.ycombinator.com/","title":"Hacker News","space":"$A","saved":false,"seen":$old},
  {"url":"https://en.wikipedia.org/wiki/Copper","title":"Copper - Wikipedia","space":"$A","saved":false,"seen":$old},
  {"url":"https://example.com/fresh","title":"Fresh","space":"$A","saved":false,"seen":$now}]}
JSON
defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
defaults write "$domain" sidebar -bool true
bench() { "$root/bench" --world "$world" "$@"; }
launch() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="${SEARCH_MCP_PORT:-4606}" "$app" >>"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return 0; sleep 0.5; done
  fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
}
shot() { [ -n "${SHOTS:-}" ] && bench sections picture "$SHOTS/$1.png" 0 >/dev/null 2>&1 && echo "     picture $SHOTS/$1.png" || true; }

launch
sleep 2
count() { bench sections | sed -n 's/^recently cleaned (\([0-9]*\)).*/\1/p'; }
id_of() { bench tabs | grep -m1 -F "$1" | grep -oE '[0-9a-f]{8}' | head -1; }
bench sections >"$tmp/s0.txt"; cat "$tmp/s0.txt"
inbox=$(id_of mail.google.com); cal=$(id_of calendar.google.com); fresh=$(id_of example.com/fresh)
[ -n "$inbox" ] && [ -n "$cal" ] && [ -n "$fresh" ] || fail "rows not found: $(bench tabs)"

# The sweep at launch: the two rows unseen for 30 h are in Recently Cleaned.
grep -q "recently cleaned (2)" "$tmp/s0.txt" && grep -q "Hacker News" "$tmp/s0.txt" && grep -q "Copper - Wikipedia" "$tmp/s0.txt" \
  || fail "the launch sweep did not put the two stale rows in Recently Cleaned"
ok "the launch's Today sweep put the two stale rows in Recently Cleaned"

# 1. Calendar (Today) dragged onto Inbox's middle (Saved), by real mouse events.
bench sections target >"$tmp/t.txt"
yi=$(awk -v k="$inbox" '$2 == k { print $5 }' "$tmp/t.txt")
yc=$(awk -v k="$cal" '$2 == k { print $5 }' "$tmp/t.txt")
[ -n "$yi" ] && [ -n "$yc" ] || fail "no row frames: $(cat "$tmp/t.txt")"
dy=$(python3 -c "print(round($yi - $yc, 1))")
# Six points under the middle: still onto it, and the ring shows past the card.
dy=$(python3 -c "print(round($dy + 6, 1))")
bench sections drag "$cal" "$dy" 16 hold >/dev/null
sleep 1.2
bench sections target | tee "$tmp/held.txt" | grep -m1 '^drop' || true
grep -q "'onto': '$inbox'" "$tmp/held.txt" || fail "held over Inbox's middle, the target is not onto it: $(grep '^drop' "$tmp/held.txt")"
ok "held over the middle of a Saved row: the target is that row (onto)"
shot ardia-tabs-onto-held
bench sections release >/dev/null; sleep 1
google=$(bench groups | jq -c '[.groups[] | select(.name == "Google")] | first')
echo "     folder: $google"
[ "$(jq '.tabs | length' <<<"$google")" = 2 ] || fail "no Google folder of two after the drop: $(bench groups | jq -c .)"
bench sections >"$tmp/s1.txt"
grep -E "^ +. $cal .*\[Google\]" "$tmp/s1.txt" >/dev/null && grep -E "^ +. $inbox .*\[Google\]" "$tmp/s1.txt" >/dev/null \
  || fail "Inbox and Calendar are not both in Google: $(cat "$tmp/s1.txt")"
ok "dropped: a new folder Google holds Inbox and Calendar, both Saved"
shot ardia-tabs-onto-folder

# 2. Clean Up (⌥⌘K): a row aged past the 24 h window goes to Recently Cleaned.
bench sections age "$fresh" 30 >/dev/null
bench sections cleanup >"$tmp/c.txt"; cat "$tmp/c.txt"
grep -q "archived 1 tab" "$tmp/c.txt" || fail "cleanup did not take the stale row"
grep -q "recently cleaned (3)" "$tmp/c.txt" && grep -q "Fresh" "$tmp/c.txt" || fail "Recently Cleaned does not list it"
ok "Clean Up closed the stale Today row into Recently Cleaned (3 now)"
sleep 1; shot ardia-tabs-recently-cleaned
if [ -n "${SHOTS:-}" ]; then
  bench sections cleaned "$SHOTS/ardia-tabs-cleaned-list.png" >/dev/null && echo "     picture $SHOTS/ardia-tabs-cleaned-list.png"
  bench sections cleaned "$SHOTS/ardia-tabs-cleaned-list-dark.png" dark >/dev/null || true
fi
hn=$(awk '/Hacker News/ { print $1; exit }' "$tmp/c.txt")
bench sections restore "$hn" >"$tmp/r.txt"; cat "$tmp/r.txt"
grep -q "Hacker News" <(bench tabs) || fail "Hacker News did not come back"
grep -q "recently cleaned (2)" "$tmp/r.txt" || fail "the restored entry is still listed"
ok "one entry restored into Today, the other still listed"

# Clear (⇧⌘K) feeds it too, and Undo takes its entries back out.
c0=$(count); bench tabs clear; sleep 0.5; c1=$(count)
bench tabs undo; sleep 0.5; c2=$(count)
echo "     Recently Cleaned: ${c0:-0} → Clear → ${c1:-0} → Undo → ${c2:-0}"
[ "${c1:-0}" -gt "${c0:-0}" ] || fail "Clear did not add to Recently Cleaned"
[ "${c2:-0}" = "${c0:-0}" ] || fail "Clear's Undo left its entries in Recently Cleaned"
ok "Clear adds to Recently Cleaned and its Undo takes them back out"

bench sections restore all >"$tmp/ra.txt"; cat "$tmp/ra.txt"
grep -q "en.wikipedia.org" <(bench tabs) && grep -q "example.com/fresh" <(bench tabs) || fail "Restore All did not bring Wikipedia and Fresh back"
grep -q "recently cleaned" "$tmp/ra.txt" && fail "Recently Cleaned not empty after Restore All"
ok "Restore All brought the rest back; the list is empty"

# 3. A relaunch keeps Recently Cleaned (and the folder).
# `sections archive 0`: the sweep against no age at all, every Today row but the one in front.
bench sections archive 0 | tee "$tmp/a0.txt"
grep -q "archived 2 tab" "$tmp/a0.txt" && grep -q "recently cleaned (2)" "$tmp/a0.txt" || fail "archive 0 did not sweep Wikipedia and Fresh into Recently Cleaned"
ok "sections archive 0 swept the two Today rows not in front into Recently Cleaned"
before=$(count)
[ "${before:-0}" -ge 1 ] || fail "nothing cleaned before the relaunch"
bench windows quit >/dev/null
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
stop
[ -f "$folder/cleaned.json" ] || fail "no cleaned.json written"
launch; sleep 1.5
after=$(count)
[ "${after:-0}" = "$before" ] || fail "Recently Cleaned after relaunch: ${after:-0}, before: $before"
bench groups | jq -e '.groups[] | select(.name == "Google")' >/dev/null || fail "the Google folder did not survive the relaunch"
ok "relaunch: Recently Cleaned ($after) and the Google folder are still there"
echo "PASS ardia-tabs-e2e"
