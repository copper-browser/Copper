#!/bin/bash
# The Move-in sheet comes up once, in one window, at its step's size, and goes when
# it is told to — whatever door it was opened through, with two windows open,
# and while the page behind it is rebuilt. Counts every open, present,
# dismiss and scan (`bench flow events`) and checks:
#   - two windows => exactly one sheet, hung from the window that asked;
#   - presents == the opens that brought it up, dismisses == closes, never
#     two at once, at most one scan per open;
#   - the sheet is always 560 wide, and the same step is always the same size
#     (its height follows the step: the preview of one source, every time);
#   - Escape closes it, Return presses the primary button;
#   - taking the page away from under it does not dismiss it;
#   - reopening after a move starts fresh (the picker, not the last summary);
#   - nothing reads another browser's folder at launch;
#   - ⌘Q quits with the sheet up.
#
# A fresh headless probe world launched through LaunchServices (`open`), a
# generated one-tab Chrome profile, never a real browser folder, never the
# keychain. Run after ./build.sh:
#   docs/fixtures/flow-sheet-e2e.sh [build/Copper.app]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=${1:-"$ROOT/build/Copper.app"}
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-sheet.XXXXXX")
WORLD="flowsheet$(date +%s)$$"
PORT=$((43000 + $$ % 9000))
DOMAIN="com.collinrijock.copper.test.$WORLD"
HOME_WORLD="$HOME/Library/Application Support/Copper ($WORLD)"
PID=""
cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
      "$APP/Contents/MacOS/Copper"*) kill -9 "$PID" 2>/dev/null || : ;;
    esac
  fi
  defaults delete "$DOMAIN" >/dev/null 2>&1 || :
  rm -rf "$HOME_WORLD" "$TEMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$TEMP/copper.log" ] || tail -n 12 "$TEMP/copper.log" >&2; exit 1; }
ok() { echo "ok: $*"; }
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
# check LABEL JQ-EXPR JSON
check() { printf '%s\n' "$3" | jq -e "$2" >/dev/null || fail "$1: $3"; }
# until JQ-EXPR holds for `flow state` (5 s)
until_state() {
  local state
  for _ in $(seq 1 50); do
    state=$(B flow state)
    if printf '%s\n' "$state" | jq -e "$1" >/dev/null; then printf '%s\n' "$state"; return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $1: $state"
}

# A one-tab Chromium profile (SNSS v1: window, tab, selected navigation).
PROFILE="$TEMP/Chrome/Default"
mkdir -p "$PROFILE/Sessions"
printf '{"profile":{"name":"Default"}}\n' > "$PROFILE/Preferences"
perl -e '
  use strict; use warnings;
  sub cmd { my ($id,$p) = @_; return pack("vC", length($p)+1, $id).$p }
  sub field { my ($s) = @_; my $p = pack("V",length($s)).$s; return $p.("\0" x ((4-length($s)%4)%4)) }
  sub field16 { my ($s) = @_; my $p = pack("v*", unpack("C*", $s)); return pack("V",length($s)).$p.("\0" x ((4-length($p)%4)%4)) }
  my $nav = pack("V2", 7, 0).field("https://example.invalid/sheet").field16("Sheet").pack("V2",0,0);
  $nav = pack("V",length($nav)).$nav;
  print "SNSS",pack("V",1),cmd(0,pack("V2",1,7)),cmd(2,pack("V2",7,0)),cmd(8,pack("V2",1,0)),cmd(6,$nav);
' > "$PROFILE/Sessions/Current Session"

[ ! -e "$HOME_WORLD" ] || fail "probe world already exists"
defaults write "$DOMAIN" bench -bool true
defaults write "$DOMAIN" welcomed -bool true
LAUNCHED=$(date "+%Y-%m-%d %H:%M:%S")
open -n -g --stderr "$TEMP/copper.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 \
  --env SEARCH_MCP_PORT="$PORT" --env SEARCH_HEADLESS_SIZE=1440x960 "$APP"
for _ in $(seq 1 120); do
  PID=$(sed -n 's/.*on — pid \([0-9][0-9]*\).*/\1/p' "$TEMP/copper.log" 2>/dev/null | head -1)
  [ -n "$PID" ] && B tabs >/dev/null 2>&1 && break
  sleep 0.5
done
[ -n "$PID" ] || fail "headless probe did not start"
case "$(ps -p "$PID" -o command= 2>/dev/null || :)" in
  "$APP/Contents/MacOS/Copper"*) ;;
  *) PID=""; fail "pid in the log is not this build" ;;
esac
ok "probe $WORLD up (pid $PID)"

# Nothing at launch: Flow exists only once asked, and asking reads nothing.
EVENTS=$(B flow events)
check "no source read before the sheet opens" '(.counts.refresh // 0) == 0 and (.counts.scan // 0) == 0' "$EVENTS"
ok "no source read at launch"

# Limit the list first (reads nothing), then point Chrome at the fixture: the
# real Chrome folder is never listed by this run.
B flow limit --only Chrome >/dev/null
B flow root --source Chrome --path "$TEMP/Chrome" >/dev/null
B windows new >/dev/null
for _ in $(seq 1 40); do
  [ "$(B windows | jq '.windows | length')" = 2 ] && break
  sleep 0.25
done
[ "$(B windows | jq '.windows | length')" = 2 ] || fail "second window did not open"
B flow events --clear >/dev/null
ok "two windows, Chrome fixture only"

SIZE=""
OPENS=0
CLOSES=0
round=0
for pass in 1 2 3; do
  for door in bench command menu settings; do
    round=$((round + 1))
    win=$((round % 2))
    other=$((1 - win))
    B flow open --via "$door" --window "$win" >/dev/null
    OPENS=$((OPENS + 1))
    STATE=$(until_state '.showing and .sheetVisible and .attached')
    check "$door: one sheet across both windows" '.attachedSheets == 1 and .flowSheets == 1' "$STATE"
    [ "$(printf '%s\n' "$STATE" | jq '.sheet[0]')" = 560 ] || fail "$door: sheet is not 560 wide"
    # The other window asks too, while it is up: still one sheet.
    B flow open --via bench --window "$other" >/dev/null
    sleep 0.3
    STATE=$(B flow state)
    check "$door: a second ask adds no sheet" '.attachedSheets == 1 and .flowSheets == 1 and .showing' "$STATE"
    STATE=$(until_state '.phase == "preview"')
    sleep 0.4   # the sheet takes the preview's height once it is drawn
    NOW=$(B flow state | jq -c '.sheet')
    [ -z "$SIZE" ] && SIZE="$NOW"
    [ "$NOW" = "$SIZE" ] || fail "$door: the same preview came up at another size: $SIZE -> $NOW"
    if [ "$door" = settings ]; then
      [ "$(B probe | jq '.settings')" = false ] || fail "settings door left Settings open"
    fi
    if [ $((round % 2)) = 0 ]; then B flow key escape >/dev/null; else B flow close >/dev/null; fi
    CLOSES=$((CLOSES + 1))
    until_state '(.showing | not) and .open == false' >/dev/null
  done
done
EVENTS=$(B flow events --all)
check "presents == opens that brought it up" ".counts.present == $OPENS" "$EVENTS"
check "dismisses == closes" ".counts.dismiss == $CLOSES" "$EVENTS"
check "never two at once" '.overlapping == false' "$EVENTS"
check "at most one scan per open" '.scansPerOpen <= 1' "$EVENTS"
ok "$OPENS opens through bench/command/menu/settings on alternating windows: $OPENS presents, $CLOSES dismisses, one sheet, size $SIZE"

# The page behind the sheet is taken away (another window selects its tab):
# the sheet stays, nothing is dismissed and presented again.
B flow events --clear >/dev/null
B flow open --via bench --window 1 >/dev/null
until_state '.showing and .phase == "preview"' >/dev/null
TAB=$(B windows | jq -r '.windows[1] as $w | $w.tabIDs[$w.active]')
[ -n "$TAB" ] && [ "$TAB" != null ] || fail "window 1 has no active tab"
B windows select 0 "$TAB" >/dev/null
sleep 0.8
[ "$(B windows | jq -r '.windows[1].taken')" = "$TAB" ] || fail "window 1's page was not taken"
STATE=$(B flow state)
check "sheet survives its page being taken" '.showing and .attached and .attachedSheets == 1' "$STATE"
EVENTS=$(B flow events)
check "no dismiss while the page was rebuilt" '(.counts.dismiss // 0) == 0 and .counts.present == 1' "$EVENTS"
ok "taking the page from under the sheet changes nothing"

# ⌘ shortcuts typed on the sheet never reach the window behind it (they used
# to: ⌘W closed the tab under the sheet, ⌘T and ⌘, opened things nobody could
# see). ⌘T, ⌘K, ⌘L, ⌘N and ⌘, wait; ⌘W closes the sheet, not a tab.
TABS0=$(B windows | jq '[.windows[].tabIDs | length] | add')
WINS0=$(B windows | jq '.windows | length')
for key in cmd-t cmd-k cmd-l cmd-n cmd-comma; do B flow key "$key" >/dev/null; done
sleep 0.4
check "⌘ shortcuts leave the sheet up" '.showing and .attachedSheets == 1' "$(B flow state)"
check "nothing opened behind the sheet" '.settings == false and .launching == false' "$(B probe)"
[ "$(B windows | jq '.windows | length')" = "$WINS0" ] || fail "⌘N behind the sheet opened a window"
B flow key cmd-w >/dev/null
until_state '(.showing | not) and .open == false' >/dev/null
[ "$(B windows | jq '[.windows[].tabIDs | length] | add')" = "$TABS0" ] || fail "⌘W on the sheet closed a tab"
ok "⌘T ⌘K ⌘L ⌘N ⌘, wait behind the sheet; ⌘W closes the sheet, not a tab"
B flow open --via bench --window 1 >/dev/null
until_state '.showing and .phase == "preview"' >/dev/null

# Return presses the primary button: a tabs-only move from the fixture.
B flow choose --only tabs >/dev/null
B flow key return >/dev/null
for _ in $(seq 1 100); do
  PHASE=$(B flow state | jq -r '.phase')
  [ "$PHASE" = done ] && break
  sleep 0.1
done
[ "$PHASE" = done ] || fail "Return did not run the move (phase $PHASE)"
ok "Return moved the fixture in"
B flow close >/dev/null
until_state '.showing | not' >/dev/null

# Reopening after a move starts fresh: the picker, not the last summary.
B flow open --via command >/dev/null
STATE=$(until_state '.showing and .phase != "done"')
check "reopen after done is the picker" '.phase == "idle" or .phase == "scanning" or .phase == "preview"' "$STATE"
check "reopen restores the switches" '.choice | all' "$STATE"
ok "reopen after done shows the picker with every switch on"
B flow key escape >/dev/null
until_state '.showing | not' >/dev/null

# A move the person closes the sheet on keeps going, and its summary waits
# for the next open — not the picker, as if nothing had happened. Done then
# starts fresh.
B flow slow --seconds 1 >/dev/null
B flow open --via command >/dev/null
until_state '.showing and .phase == "preview"' >/dev/null
B flow choose --only tabs >/dev/null
B flow key return >/dev/null   # Move in again
B flow key return >/dev/null   # Bring over …
until_state '.phase == "moving"' >/dev/null
B flow key cmd-w >/dev/null
until_state '(.showing | not) and .phase == "done"' >/dev/null
B flow slow --seconds 0 >/dev/null
B flow open --via command >/dev/null
check "a move closed mid-way shows its summary next time" '.phase == "done"' "$(until_state '.showing')"
B flow done >/dev/null
until_state '.showing | not' >/dev/null
B flow open --via command >/dev/null
until_state '.showing and .phase != "done"' >/dev/null
B flow key escape >/dev/null
until_state '.showing | not' >/dev/null
ok "closed mid-move: the move finished, its summary waited for the next open, Done started fresh"

# Two windows' worth of sheets never happened at any point.
check "never two at once (whole run)" '.overlapping == false' "$(B flow events --all)"

# Nothing at launch reached another browser's protected folder.
# tccd logs the request (AUTHREQ_CTX, by message id) and who made it
# (AUTHREQ_ATTRIBUTION, same id): count App Data requests made by this pid.
# The build's own bundle id (a dev build's is com.collinrijock.copper.dev):
# a hard-coded one never matched, and the check passed whatever happened.
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || :)
if command -v log >/dev/null && [ -n "$BUNDLE" ]; then
  HITS=$(log show --style compact --start "$LAUNCHED" --predicate 'process == "tccd"' 2>/dev/null | awk \
    -v want="accessing={TCCDProcess: identifier=$BUNDLE, pid=$PID," '
    /AUTHREQ_CTX/ && /AppDataDetailed/ { if (match($0, /msgID=[0-9.]+/)) ids[substr($0, RSTART, RLENGTH)] = 1 }
    /AUTHREQ_ATTRIBUTION/ && index($0, want) { if (match($0, /msgID=[0-9.]+/)) { id = substr($0, RSTART, RLENGTH); if (id in ids) n++ } }
    END { print n + 0 }')
  [ "${HITS:-0}" = 0 ] || fail "tccd saw $HITS App Data requests from pid $PID"
  ok "no App Data request from this run"
fi

# ⌘Q with the sheet up quits.
B flow open --via bench >/dev/null
until_state '.showing' >/dev/null
B windows quit >/dev/null || :
for _ in $(seq 1 40); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$PID" 2>/dev/null; then fail "⌘Q with the sheet up did not quit"; fi
PID=""
ok "⌘Q with the sheet up quit"
echo "ok: flow sheet end to end"
