#!/bin/bash
# Move in from Safari, end to end, in fresh headless worlds. Synthetic data
# only (docs/fixtures/flow-safari-fixture.py) unless --data names a copy; a
# probe never looks at this Mac's own Safari.
#
# Safari — locked, then its export:
#   - with no copy given, Safari is locked (a probe reads no Safari folder): the
#     card has one sentence, "Allow Full Disk Access…" and "Use an export
#     instead…"; Allow names Full Disk Access, and the card then says what
#     else it takes;
#   - a file that isn't Safari's export is said plainly; the export zip makes
#     Safari readable without unlocking it, and it is picked for you;
#   - the counts are the export's; Return moves; the summary has a line per
#     category and says what stayed in Safari (open tabs, cards, extensions);
#     the passwords land in the world's file keychain, never the real one;
#   - moving the same export again adds nothing;
#   - an export with only passwords in it leaves the bookmarks alone (FS-02);
#   - a bookmark folder the person moved is theirs: re-importing keeps it (FS-03),
#     and a bookmark they made themselves survives every Safari move.
# Safari — its own files (a copy, as if Copper had Full Disk Access):
#   - windows, tab groups and pinned tabs become spaces; private windows never;
#   - moving again makes no space and adds no tab, bookmark or place.
# A real-scale copy (--data DIR, e.g. /tmp/cux-safari-data with Safari/ and
#   Container/): read-only, counts only, moved twice; the copy is unchanged.
# Chrome, Safari and Arc in one world: each source's spaces once, a second
#   round adds nothing; a name two browsers share is told apart once.
#
#   docs/fixtures/flow-safari-e2e.sh [--data DIR] [--shots DIR] [build/Copper.app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA=""
SHOTS=""
APP="$ROOT/build/Copper.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --data) DATA="$2"; shift 2 ;;
    --shots) SHOTS="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-safari.XXXXXX")
PIDS=()
WORLDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    case "$(ps -p "$pid" -o command= 2>/dev/null || :)" in
      "$APP/Contents/MacOS/Copper"*) kill "$pid" 2>/dev/null || :; sleep 1; kill -9 "$pid" 2>/dev/null || : ;;
    esac
  done
  for world in "${WORLDS[@]:-}"; do
    [ -n "$world" ] || continue
    defaults delete "com.collinrijock.copper.test.$world" >/dev/null 2>&1 || :
    rm -rf "$HOME/Library/Application Support/Copper ($world)"
  done
  rm -rf "$TEMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; for f in "$TEMP"/*.log; do [ -f "$f" ] && tail -n 8 "$f" >&2; done; exit 1; }
ok() { echo "ok: $*"; }
check() { printf '%s\n' "$3" | jq -e "$2" >/dev/null || fail "$1: $3"; }
WORLD=""
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
until_state() {
  local state
  for _ in $(seq 1 150); do
    state=$(B flow state)
    if printf '%s\n' "$state" | jq -e "$1" >/dev/null; then printf '%s\n' "$state"; return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $1: $state"
}
SIZE=normal
shot() { # the sheet as drawn, light and dark
  [ -n "$SHOTS" ] || return 0
  mkdir -p "$SHOTS"
  for look in light dark; do
    B ui look "$look" >/dev/null
    sleep 0.4
    B flow shot --path "$SHOTS/safari-$1-$SIZE-$look.png" >/dev/null || fail "shot $1 $look"
  done
  B ui look light >/dev/null
}
launch() { # launch NAME [WxH]
  WORLD="flowsafari$1$(date +%s)$$"
  WORLDS+=("$WORLD")
  local port=$((47000 + ($$ + ${#WORLDS[@]}) % 9000))
  defaults write "com.collinrijock.copper.test.$WORLD" bench -bool true
  defaults write "com.collinrijock.copper.test.$WORLD" welcomed -bool true
  defaults write "com.collinrijock.copper.test.$WORLD" probe.keychain -string file
  defaults write "com.collinrijock.copper.test.$WORLD" flow.installed -string "Chrome,Arc"
  open -n -g --stderr "$TEMP/$1.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 \
    --env SEARCH_MCP_PORT="$port" --env SEARCH_HEADLESS_SIZE="${2:-1440x960}" "$APP"
  local pid=""
  for _ in $(seq 1 120); do
    pid=$(sed -n 's/.*on — pid \([0-9][0-9]*\).*/\1/p' "$TEMP/$1.log" 2>/dev/null | head -1)
    [ -n "$pid" ] && B tabs >/dev/null 2>&1 && break
    sleep 0.5
  done
  [ -n "$pid" ] || fail "headless probe $1 did not start"
  case "$(ps -p "$pid" -o command= 2>/dev/null || :)" in
    "$APP/Contents/MacOS/Copper"*) ;;
    *) fail "pid in the $1 log is not this build" ;;
  esac
  PIDS+=("$pid")
  ok "probe $WORLD up (pid $pid)"
}
quit() {
  local pid="${PIDS[${#PIDS[@]}-1]}"
  B windows quit >/dev/null || :
  for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.25; done
  fail "probe $pid did not quit"
}
take() { # take FILE — Safari's export pane takes a file; prints file-status
  B flow file --source Safari --path "$1"
}

FX="$TEMP/fixture"
python3 "$ROOT/docs/fixtures/flow-safari-fixture.py" "$FX" >/dev/null
printf 'title,url\nNot passwords,https://exported.invalid/\n' > "$TEMP/notes.csv"

# ---------------------------------------------------------------- export
launch export
B flow limit --only Safari >/dev/null
# The person's own bookmark, made before any move: every Safari move leaves it.
OWN=$(B open "https://own.invalid/mine")
B windows select 0 "$OWN" >/dev/null
sleep 0.5
B bar "Bookmark This Page" --go >/dev/null
own() { B flow bookmarks | jq -e '[.roots[] | select(.url == "https://own.invalid/mine")] | length == 1' >/dev/null; }
own || fail "couldn't make the person's own bookmark: $(B flow bookmarks)"
check "a probe lists no Safari unless named" '.sources | length == 1' "$(B flow sources)"
B flow events --clear >/dev/null
B flow open >/dev/null
STATE=$(until_state '.showing and .sourcesKnown')
check "locked card" '.sources == [{"name":"Safari","locked":true,"empty":false}] and .selected == "" and .phase == "idle" and .readable == []' "$STATE"
check "Allow is Full Disk Access" '.page | endswith("Privacy_AllFiles")' "$(B flow allow --source Safari)"
check "asked" '.askedAccess == ["Safari"]' "$(B flow state)"
shot locked
B flow activate >/dev/null
sleep 0.5
STATE=$(B flow state)
check "still locked after coming back" '.sources[0].locked and .selected == ""' "$STATE"
ok "locked: one sentence, Allow Full Disk Access… (Privacy_AllFiles), still locked after coming back"

B flow export --source Safari >/dev/null
until_state '.exporting == "Safari"' >/dev/null
shot export
R=$(take "$TEMP/notes.csv")
check "a file that isn't the export" '(.ok | not) and (.text | length > 0) and .safariExport == ""' "$R"
shot export-wrong-file
R=$(take "$FX/export.zip")
check "export taken" '.running == false and .safariExport == "export.zip"' "$R"
STATE=$(until_state '.phase == "preview" and .selected == "Safari"')
check "export makes Safari readable, still locked, pane closed" '.readable == ["Safari"] and .exports == ["Safari"] and .sources[0].locked and .exporting == ""' "$STATE"
shot export-loaded
SCAN=$(B flow scan --source Safari)
check "export counts" '.fromExport and (.direct | not) and .tabs == 0 and .bookmarks == 4 and .readingList == 2 and .places == 3 and .passwords == 2 and .passwordsSkipped == 1 and .cards == 2 and .extensions == 1' "$SCAN"
ok "export: $(printf '%s' "$SCAN" | jq -r '"\(.bookmarks) bookmarks, \(.readingList) in Reading List, \(.places) places, \(.passwords) passwords; stays: \(.stays)"')"

B flow slow --seconds 0.8 >/dev/null
B flow key return >/dev/null
until_state '.phase == "moving" and ((.lines // []) | length) >= 1' >/dev/null
shot moving
until_state '.phase == "done"' >/dev/null
B flow slow --seconds 0 >/dev/null
shot done
FIRST=$(B flow status)
printf '%s\n' "$FIRST" | jq -r '.summary[], (.stayed // [])[]' | sed 's/^/     /'
check "first export move" '.bookmarks == 6 and .readingList == 2 and .places == 3 and .passwords == 2 and .tabs == 0 and .spacesMade == 0' "$FIRST"
check "a line per category, no tabs line" '([.summary[] | startswith("✓")] | all) and ([.summary[] | select(test("Tabs"))] | length == 0) and (.summary | length == 3)' "$FIRST"
check "says what stayed" '(.stayed | length) >= 3 and ([.stayed[] | select(test("tabs"))] | length == 1) and ([.stayed[] | select(test("card"))] | length == 1) and ([.stayed[] | select(test("xtension"))] | length == 1)' "$FIRST"
check "no Chrome guide" '.guideOffered | not' "$FIRST"
SECRETS=$(B flow secrets)
check "passwords in the world's file keychain" '.sink == "probe-file" and ([.passwords[] | select(.host | endswith("safari-fixture.example"))] | length == 2)' "$SECRETS"
BOOKMARKS=$(B flow bookmarks | jq '.count')
B flow key return >/dev/null
until_state '.showing | not' >/dev/null
ok "first move: 6 bookmarks (2 from the Reading List), 3 places, 2 passwords into the world's file keychain; what stayed is said"

SECOND=$(B flow move --source Safari --only tabs,bookmarks,history,passwords 2>/dev/null)
printf '%s\n' "$SECOND" | jq -r '.summary[]' | sed 's/^/     /'
check "second export move adds nothing" '.bookmarksNew == 0 and .placesNew == 0 and .passwordsNew == 0 and .tabs == 0 and .spacesMade == 0' "$SECOND"
[ "$(B flow bookmarks | jq '.count')" = "$BOOKMARKS" ] || fail "the second move changed the bookmarks"
check "still two passwords" '[.passwords[] | select(.host | endswith("safari-fixture.example"))] | length == 2' "$(B flow secrets)"
ok "second move of the same export: nothing new"

PWONLY=$(B flow move --source Safari --zip "$FX/pwonly.zip" --only bookmarks,passwords 2>/dev/null)
printf '%s\n' "$PWONLY" | jq -r '.summary[]' | sed 's/^/     /'
check "passwords-only export reads no bookmarks" '.bookmarks == 0 and .passwordsNew == 0' "$PWONLY"
[ "$(B flow bookmarks | jq '.count')" = "$BOOKMARKS" ] || fail "a passwords-only export changed the bookmarks (FS-02)"
ok "FS-02: an export with only passwords left the $BOOKMARKS bookmarks alone"

MENU=$(B flow bookmarks | jq -r '[.roots[] | select(.title == "Bookmarks Menu")][0].id')
[ -n "$MENU" ] && [ "$MENU" != null ] || fail "no Bookmarks Menu folder from Safari: $(B flow bookmarks)"
B flow bookmark-move --id "$MENU" >/dev/null
AGAIN=$(B flow move --source Safari --zip "$FX/export.zip" --only bookmarks 2>/dev/null)
B flow bookmarks | jq -e --arg id "$MENU" '[.roots[] | select(.id == $id)] | length == 1' >/dev/null || fail "re-import removed the folder the person moved (FS-03)"
ok "FS-03: the Bookmarks Menu folder the person moved stayed theirs through a re-import"
B flow export --source Safari --clear >/dev/null

# ---------------------------------------------------------------- direct
B flow root --source Safari --path "$FX/direct" >/dev/null
SCAN=$(B flow scan --source Safari)
check "direct counts" '.direct and (.fromExport | not) and .tabs == 7 and .spaces == 3 and .pins == 2 and .bookmarks == 4 and .readingList == 3 and .places == 3 and (.hasPasswords | not)' "$SCAN"
B flow open --again >/dev/null
until_state '.showing and .phase == "preview" and .selected == "Safari"' >/dev/null
shot direct
take "$FX/export.zip" >/dev/null
until_state '.phase == "preview" and .exports == ["Safari"]' >/dev/null
check "files and export together" '.direct and .fromExport and .tabs == 7 and .passwords == 2' "$(B flow scan --source Safari)"
shot direct-and-export
B flow export --source Safari --clear >/dev/null
B flow close >/dev/null; until_state '.showing | not' >/dev/null
SPACES0=$(B flow spaces | jq '.spaces | length')
DIRECT=$(B flow move --source Safari --only tabs,bookmarks,history,passwords 2>/dev/null)
printf '%s\n' "$DIRECT" | jq -r '.summary[], (.stayed // [])[]' | sed 's/^/     /'
check "direct move" '.spacesMade == 3 and .tabs == 7 and .placesNew == 3' "$DIRECT"
check "passwords stayed (no export)" '[.stayed[] | select(test("assword"))] | length == 1' "$DIRECT"
SPACES1=$(B flow spaces | jq '.spaces | length')
[ "$SPACES1" = $((SPACES0 + 3)) ] || fail "spaces: $SPACES0 → $SPACES1, not +3"
check "registry" '.registry | length == 3' "$(B flow registry --source Safari)"
B flow spaces | jq -e '[.spaces[] | .tabs] | all(. > 0)' >/dev/null || fail "an empty space was made"
B flow spaces | jq -e '[.spaces[].name] | map(select(test("secret|Secret|Private"))) | length == 0' >/dev/null || fail "a private window came over"
B flow open --again >/dev/null
until_state '.showing and .phase == "preview" and .selected == "Safari"' >/dev/null
B flow choose --only tabs,bookmarks,history >/dev/null
B flow key return >/dev/null
until_state '.phase == "done"' >/dev/null
shot done-again
REDO=$(B flow status)
printf '%s\n' "$REDO" | jq -r '.title, .summary[]' | sed 's/^/     /'
B flow key return >/dev/null
until_state '.showing | not' >/dev/null
check "direct twice adds nothing" '.tabs == 0 and .spacesMade == 0 and .spacesFilled == 0 and .bookmarksNew == 0 and .placesNew == 0' "$REDO"
[ "$(B flow spaces | jq '.spaces | length')" = "$SPACES1" ] || fail "second direct move changed the spaces"
B flow spaces | jq -e '[.spaces[] | select(.name | test("\\(Safari\\)"))] | length == 0' >/dev/null || fail "a (Safari) twin exists"
own || fail "a Safari move took the person's own bookmark"
ok "direct: 3 spaces, 7 tabs (2 pinned), private window left out; twice adds nothing; the person's own bookmark is still there"
quit

# ---------------------------------------------------------------- min size
if [ -n "$SHOTS" ]; then
  SIZE=min
  launch small 640x420
  B flow limit --only Safari >/dev/null
  B flow open >/dev/null
  until_state '.showing and .sourcesKnown' >/dev/null
  shot locked
  B flow export --source Safari >/dev/null
  until_state '.exporting == "Safari"' >/dev/null
  shot export
  take "$FX/export.zip" >/dev/null
  until_state '.phase == "preview" and .selected == "Safari"' >/dev/null
  shot export-loaded
  B flow key return >/dev/null
  until_state '.phase == "done"' >/dev/null
  shot done
  quit
  SIZE=normal
fi

# ---------------------------------------------------------------- real-scale copy
if [ -n "$DATA" ]; then
  [ -d "$DATA/Safari" ] || fail "--data needs a folder with Safari/ (and Container/)"
  SUM0=$(find "$DATA/Safari" "$DATA/Container" -type f \( -name 'Bookmarks.plist' -o -name 'History.db*' -o -name 'SafariTabs.db*' \) -exec shasum {} + 2>/dev/null | sort | shasum)
  launch data
  B flow limit --only Safari >/dev/null
  B flow root --source Safari --path "$DATA" >/dev/null
  SCAN=$(B flow scan --source Safari)
  check "the copy reads" '.direct and .places > 0' "$SCAN"
  ok "real-scale copy: $(printf '%s' "$SCAN" | jq -r '"\(.tabs) tabs in \(.spaces) spaces (\(.pins) pinned, \(.tabGroups) tab groups), \(.bookmarks) bookmarks, \(.readingList) in Reading List, \(.places) places"')"
  T0=$(date +%s)
  FIRST=$(B flow move --source Safari --only tabs,bookmarks,history 2>/dev/null)
  ok "moved in $(( $(date +%s) - T0 )) s: $(printf '%s' "$FIRST" | jq -r '"\(.spacesMade) spaces, \(.tabs) tabs, \(.bookmarks) bookmarks, \(.placesNew) places"')"
  SPACES1=$(B flow spaces | jq '.spaces | length')
  SECOND=$(B flow move --source Safari --only tabs,bookmarks,history 2>/dev/null)
  check "real-scale twice adds nothing" '.tabs == 0 and .spacesMade == 0 and .spacesFilled == 0 and .bookmarksNew == 0 and .placesNew == 0' "$SECOND"
  [ "$(B flow spaces | jq '.spaces | length')" = "$SPACES1" ] || fail "second move changed the spaces"
  quit
  SUM1=$(find "$DATA/Safari" "$DATA/Container" -type f \( -name 'Bookmarks.plist' -o -name 'History.db*' -o -name 'SafariTabs.db*' \) -exec shasum {} + 2>/dev/null | sort | shasum)
  [ "$SUM0" = "$SUM1" ] || fail "the copy changed while Copper read it"
  ok "real-scale copy: second move added nothing; the copy is unchanged"
fi

# ---------------------------------------------------------------- one world
mkdir -p "$TEMP/Chrome/Default/Sessions"
printf '{"profile":{"name":"Default"}}\n' > "$TEMP/Chrome/Default/Preferences"
perl -e '
  use strict; use warnings;
  sub cmd { my ($id,$p) = @_; return pack("vC", length($p)+1, $id).$p }
  sub field { my ($s) = @_; my $p = pack("V",length($s)).$s; return $p.("\0" x ((4-length($s)%4)%4)) }
  sub field16 { my ($s) = @_; my $p = pack("v*", unpack("C*", $s)); return pack("V",length($s)).$p.("\0" x ((4-length($p)%4)%4)) }
  my $out = "SNSS".pack("V",1);
  my $index = 0;
  for my $url (@ARGV) {
    my $tab = 7 + $index;
    my $nav = pack("V2", $tab, 0).field($url).field16("Fixture").pack("V2",0,0);
    $nav = pack("V",length($nav)).$nav;
    $out .= cmd(0,pack("V2",1,$tab)).cmd(2,pack("V2",$tab,$index)).cmd(6,$nav);
    $index++;
  }
  print $out.cmd(8,pack("V2",1,0));
' "https://alpha.invalid/one" "https://alpha.invalid/two" > "$TEMP/Chrome/Default/Sessions/Current Session"
printf '{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[{"type":"url","name":"A","url":"https://alpha.invalid/"}]},"other":{"type":"folder","name":"Other","children":[]},"synced":{"type":"folder","name":"Mobile","children":[]}},"version":1}\n' > "$TEMP/Chrome/Default/Bookmarks"
mkdir -p "$TEMP/Arc/User Data/Default"
printf '{"profile":{"name":"Default"}}\n' > "$TEMP/Arc/User Data/Default/Preferences"
cat > "$TEMP/Arc/StorableSidebar.json" <<'JSON'
{"sidebar":{"containers":[{"global":{}},{"spaces":[{"id":"S1","title":"Research","containerIDs":["pinned","P1","unpinned","U1"]}],
"items":[{"id":"P1","childrenIds":[],"data":{}},{"id":"U1","childrenIds":["T1"],"data":{}},
{"id":"T1","title":"Beta","childrenIds":[],"data":{"tab":{"savedURL":"https://beta.invalid/one","savedTitle":"Beta"}}}],
"topAppsContainerIDs":[]}]}}
JSON

launch mixed
B flow limit --only Chrome,Safari,Arc >/dev/null
B flow root --source Chrome --path "$TEMP/Chrome" >/dev/null
B flow root --source Safari --path "$FX/direct" >/dev/null
B flow root --source Arc --path "$TEMP/Arc/User Data" >/dev/null
B flow open >/dev/null
STATE=$(until_state '.showing and .sourcesKnown')
check "three cards" '[.sources[].name] | sort == ["Arc","Chrome","Safari"]' "$STATE"
shot mixed-picker
B flow close >/dev/null; until_state '.showing | not' >/dev/null
SPACES0=$(B flow spaces | jq '.spaces | length')
MADE=0
for source in Chrome Safari Arc; do
  R=$(B flow move --source "$source" --only tabs,bookmarks,history 2>/dev/null)
  printf '%s\n' "$R" | jq -r --arg s "$source" '"     \($s): " + (.summary | join(" · "))'
  MADE=$((MADE + $(printf '%s' "$R" | jq '.spacesMade')))
done
# Chrome: one window; Safari: a window and two tab groups; Arc: one space.
[ "$MADE" = 5 ] || fail "Chrome, Safari and Arc made $MADE spaces, not 5"
SPACES1=$(B flow spaces | jq '.spaces | length')
[ "$SPACES1" = $((SPACES0 + 5)) ] || fail "spaces: $SPACES0 → $SPACES1"
for source in Chrome Safari Arc; do
  R=$(B flow move --source "$source" --only tabs,bookmarks,history 2>/dev/null)
  check "$source again adds nothing" '.tabs == 0 and .spacesMade == 0 and .spacesFilled == 0 and .bookmarksNew == 0 and .placesNew == 0' "$R"
done
[ "$(B flow spaces | jq '.spaces | length')" = "$SPACES1" ] || fail "the second round changed the spaces"
B flow spaces | jq -e '[.spaces[].name] | (length == (unique | length))' >/dev/null || fail "two spaces share a name: $(B flow spaces | jq -c '[.spaces[].name]')"
# Arc's "Research" meets Safari's "Research" tab group: the later one wears
# its browser's name, once.
B flow spaces | jq -e '[.spaces[] | select(.name | test("\\((Safari|Chrome|Arc)\\)")) | .name] == ["Research (Arc)"]' >/dev/null \
  || fail "twin spaces: $(B flow spaces | jq -c '[.spaces[].name]')"
ok "one world: Chrome 1, Safari 3, Arc 1 spaces; a second round of all three added nothing; $(B flow spaces | jq -c '[.spaces[].name]')"
quit
echo "ok: flow safari end to end"
