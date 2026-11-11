#!/bin/bash
# Chat on a shared canvas, end to end: three headless probe-world Coppers
# against one copper-cloud — Ada (world a), Ann (world b) and Ann's other Mac
# (world c, which first makes the other accounts: Ben joins the canvas, Bob is
# invited and hasn't answered, Zed is a stranger). Chat in the document, the @
# picker (members only; invited shown, not offered), chips, the panel's
# visibility and messages across a relaunch of every world — and, on
# copper-cloud 0.6.0+, mentions: the pill, the door, the notification, Open,
# read on Ann's other Mac. An older cloud gets the checks for how it degrades.
#
#   docs/fixtures/canvas-chat-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world, headless, on its own MCP port, and only the pids this
# script started are ever stopped. CHAT_WORLD=NAME names the worlds NAMEa…NAMEc
# (default chat), CHAT_PORT=N puts them on N…N+2 (default 4311), CHAT_SHOTS=DIR
# keeps pictures there (chat-*.png).
set -euo pipefail
LINK=${1:?link code}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=${2:-"$ROOT/build/Copper.app"}
NAME=${CHAT_WORLD:-chat}
PORT=${CHAT_PORT:-4311}
WA="${NAME}a"; WB="${NAME}b"; WC="${NAME}c"
PA=$PORT; PB=$((PORT + 1)); PC=$((PORT + 2))
SHOTS=${CHAT_SHOTS:-}
STAMP=$(date +%s)
PW="correct-horse-battery"
ADA="ada-$STAMP@example.com"; ANN="ann-$STAMP@example.com"; BEN="ben-$STAMP@example.com"
BOB="bob-$STAMP@example.com"; ZED="zed-$STAMP@example.com"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 1500 || true)"; fi; }

stop() {
  local pid; pid=$(cat "/tmp/copper-$1.pid" 2>/dev/null) || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$APP/Contents/MacOS/Copper"*) kill "$pid" 2>/dev/null || true ;; esac
  for _ in $(seq 1 40); do ps -p "$pid" >/dev/null 2>&1 || break; sleep 0.25; done
  rm -f "/tmp/copper-$1.pid"
}
launch() { # world port — keeps the world's folder
  local w=$1 port=$2
  SEARCH_PROBE=$w SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$port SEARCH_HEADLESS_SIZE=1440x900 \
    "$APP/Contents/MacOS/Copper" >> "/tmp/copper-$w.log" 2>&1 &
  echo $! > "/tmp/copper-$w.pid"
}
fresh() { # world port — a new world
  local w=$1 port=$2
  stop "$w"
  rm -rf "$HOME/Library/Application Support/Copper ($w)"
  defaults delete "com.collinrijock.copper.test.$w" >/dev/null 2>&1 || true
  defaults write "com.collinrijock.copper.test.$w" bench -bool true
  defaults write "com.collinrijock.copper.test.$w" welcomed -bool true
  : > "/tmp/copper-$w.log"
  launch "$w" "$port"
}
B() { "$ROOT/bench" --world "$1" "${@:2}"; }
wait_bench() { for _ in $(seq 1 80); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "bench never answered in $1"; return 1; }
json() { python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: d={'raw': raw.strip()}
try: print($1)
except Exception as e: print('')"; }
shot() { [ -n "$SHOTS" ] && mkdir -p "$SHOTS" && { B "$1" drive pane off >/dev/null 2>&1; B "$1" window "$SHOTS/$2" >/dev/null 2>&1; } || true; }
chat() { B "$1" canvas chat "${@:2}"; }
dom() { chat "$1" dom "$CID"; }
# until NAME TRIES COMMAND: retry COMMAND (eval'd) every 0.25 s
until_ok() { local n=$1; shift; for _ in $(seq 1 "$n"); do if eval "$1"; then return 0; fi; sleep 0.25; done; return 1; }
cleanup() { stop "$WA"; stop "$WB"; stop "$WC"; }
trap cleanup EXIT

echo "== launching worlds $WA $WB $WC"
fresh "$WA" "$PA"; fresh "$WB" "$PB"; fresh "$WC" "$PC"
wait_bench "$WA"; wait_bench "$WB"; wait_bench "$WC"
sleep 2
set +e

echo "== accounts"
for w in "$WA" "$WB" "$WC"; do B "$w" cloud link "$LINK" | json '"linked" if d.get("linked") else d'; done
check "Ada signs up" 'B "$WA" cloud signup "$ADA" "$PW" "Ada Lovelace" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WA" cloud status'
check "Ann signs up" 'B "$WB" cloud signup "$ANN" "$PW" "Ann Example" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WB" cloud status'
B "$WC" cloud signup "$BOB" "$PW" "Bob Banner" >/dev/null; B "$WC" cloud signout >/dev/null
B "$WC" cloud signup "$ZED" "$PW" "Zed Stranger" >/dev/null; B "$WC" cloud signout >/dev/null
check "Ben signs up" 'B "$WC" cloud signup "$BEN" "$PW" "Ben Example" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WC" cloud status'
SERVER=$(B "$WA" canvas chat mentions | json 'd.get("server") or ""')
API=$(B "$WA" canvas chat mentions | json 'd.get("mentionsApi")')
echo "  server $SERVER, mentions API: $API"

echo "== a shared canvas with Ann and Ben on it, Bob invited"
CID=$(B "$WA" canvas create "Team dinners $STAMP" | json 'd.get("id","")')
check "Ada made a shared canvas" '[ -n "$CID" ]' 'B "$WA" canvas list'
for who in "$ANN" "$BEN" "$BOB"; do B "$WA" canvas remind "$CID" "$who" >/dev/null; done
IB=$(B "$WB" canvas invites | json '[i["id"] for i in d["invites"] if "Team dinners" in i["canvas"]][0]')
B "$WB" canvas accept "$IB" >/dev/null
IC=$(B "$WC" canvas invites | json '[i["id"] for i in d["invites"] if "Team dinners" in i["canvas"]][0]')
B "$WC" canvas accept "$IC" >/dev/null
# World c becomes Ann's other Mac.
B "$WC" cloud signout >/dev/null
check "Ann signs in on her other Mac" 'B "$WC" cloud signin "$ANN" "$PW" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WC" cloud status'
B "$WA" canvas open "$CID" >/dev/null
# Something on the board: three nights, a note each.
B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"frame\",\"id\":\"f\",\"title\":\"Dinners\",\"x\":-380,\"y\":-170,\"w\":760,\"h\":300}},{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"**Mon** · Noodle bar\\n- [x] Ada\\n- [ ] Ann\",\"x\":-340,\"y\":-110,\"color\":\"yellow\"}},{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"**Tue** · Tacos\\n- [ ] Ada\\n- [x] Ben\",\"x\":-100,\"y\":-110,\"color\":\"green\"}},{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"**Wed** · Pizza\\n- [x] Ann\\n- [x] Ben\",\"x\":140,\"y\":-110,\"color\":\"pink\"}}]}" >/dev/null
check "chat is offered on the shared canvas" 'chat "$WA" state "$CID" | json "d[\"page\"][\"enabled\"]" | grep -q True' 'chat "$WA" state "$CID"'
check "…and not on Personal" 'chat "$WA" state personal | json "d[\"page\"][\"enabled\"]" | grep -q False' 'chat "$WA" state personal'
B "$WA" canvas open "$CID" >/dev/null
chat "$WA" members "$CID" >/dev/null
check "members are Ada, Ann and Ben" '[ "$(chat "$WA" members "$CID" | json "\",\".join(sorted(m[\"name\"] for m in d[\"members\"]))")" = "Ada Lovelace,Ann Example,Ben Example" ]' 'chat "$WA" members "$CID"'

echo "== the panel and the @ picker (Ada)"
check "the chat panel starts hidden" 'dom "$WA" | json "d[\"panel\"]" | grep -q False' 'dom "$WA"'
chat "$WA" toggle "$CID" >/dev/null
check "the button shows it" 'dom "$WA" | json "d[\"panel\"]" | grep -q True' 'dom "$WA"'
check "Copper keeps it as shown" 'chat "$WA" state "$CID" | json "d[\"host\"][\"open\"]" | grep -q True' 'chat "$WA" state "$CID"'
shot "$WA" chat-panel-empty.png
chat "$WA" type "$CID" "@" >/dev/null
OPTS=$(dom "$WA")
check "@ lists the members but you" '[ "$(echo "$OPTS" | json "\"|\".join(sorted(d[\"options\"]))")" = "Ann Example|Ben Example" ]' 'echo "$OPTS"'
check "Bob (invited) is shown as invited, not offered" 'echo "$OPTS" | json "d[\"invited\"]" | grep -q "Bob Banner"' 'echo "$OPTS"'
check "Zed (not on the canvas) is nowhere" '! echo "$OPTS" | grep -q "Zed"' 'echo "$OPTS"'
shot "$WA" chat-autocomplete.png
chat "$WA" type "$CID" "an" >/dev/null
check "typing filters to Ann" '[ "$(dom "$WA" | json "len(d[\"options\"])")" = "1" ]' 'dom "$WA"'
chat "$WA" enter "$CID" >/dev/null
check "Enter picks: the draft holds @Ann Example" 'dom "$WA" | json "d[\"draft\"]" | grep -q "^@Ann Example $"' 'dom "$WA"'
chat "$WA" type "$CID" "dinner at 7? menu at https://example.com/menu" >/dev/null
T0=$(python3 -c 'import time; print(time.time())')
chat "$WA" enter "$CID" >/dev/null
check "Ada's message shows Ann as a chip" 'dom "$WA" | json "[c[\"text\"] for c in d[\"chips\"]]" | grep -q "@Ann Example"' 'dom "$WA"'
check "the composer is empty again" '[ -z "$(dom "$WA" | json "d[\"draft\"]")" ]' 'dom "$WA"'

echo "== Ann"
if [ "$API" = "True" ]; then
  # Ann's canvas is closed: the pill, the door, a notification (Copper is behind).
  check "Ann gets the pill" 'until_ok 40 "chat \"$WB\" mentions | json \"(d.get(\\\"pill\\\") or {}).get(\\\"from\\\",\\\"\\\")\" | grep -q \"Ada Lovelace\""' 'chat "$WB" mentions'
  T1=$(python3 -c 'import time; print(time.time())'); echo "  pill after $(python3 -c "print(round($T1-$T0,2))") s"
  MB=$(chat "$WB" mentions)
  check "…with the excerpt" 'echo "$MB" | json "d[\"pill\"][\"excerpt\"]" | grep -q "@Ann Example dinner at 7?"' 'echo "$MB"'
  check "…a dot on the Canvas door" 'echo "$MB" | json "d[\"door\"]" | grep -q mention' 'echo "$MB"'
  check "…and a notification, Copper being behind" 'echo "$MB" | json "d[\"notices\"][-1][\"title\"]" | grep -q "Ada Lovelace mentioned you"' 'echo "$MB"'
  check "Ann's other Mac has it too" 'until_ok 40 "chat \"$WC\" mentions | json \"len(d[\\\"mentions\\\"])\" | grep -q 1"' 'chat "$WC" mentions'
  B "$WB" ui history on >/dev/null; sleep 1; shot "$WB" chat-pill-over-history.png
  B "$WB" ui look dark >/dev/null; sleep 1; shot "$WB" chat-pill-dark.png
  B "$WB" ui look light >/dev/null; B "$WB" ui history off >/dev/null
  OPEN=$(chat "$WB" pill open)
  check "Open shows the canvas" 'echo "$OPEN" | json "d[\"front\"]" | grep -q "$CID"' 'echo "$OPEN"'
  check "…with its chat, at the message, highlighted" 'dom "$WB" | json "len(d[\"flash\"])" | grep -q 1' 'dom "$WB"'
  check "…and it is read" 'chat "$WB" mentions | json "len(d[\"mentions\"])" | grep -q 0' 'chat "$WB" mentions'
  check "read on Ann's other Mac too" 'until_ok 40 "chat \"$WC\" mentions | json \"len(d[\\\"mentions\\\"]) == 0 and d[\\\"pill\\\"] is None\" | grep -q True"' 'chat "$WC" mentions'
  shot "$WB" chat-opened-from-pill.png
else
  B "$WB" canvas open "$CID" >/dev/null
  check "(older cloud) no mentions API, no pill" 'chat "$WB" mentions | json "d[\"mentionsApi\"] is not True and d[\"pill\"] is None" | grep -q True' 'chat "$WB" mentions'
  check "(older cloud) Ada's page doesn't ask Copper to notify" 'chat "$WA" state "$CID" | json "d[\"page\"][\"mentionsApi\"]" | grep -q False' 'chat "$WA" state "$CID"'
  check "(older cloud) Ann's chat button says @" 'until_ok 40 "dom \"$WB\" | json \"d[\\\"badge\\\"]\" | grep -q @"' 'dom "$WB"'
  shot "$WB" chat-badge-closed.png
  chat "$WB" toggle "$CID" >/dev/null
fi
check "Ann sees Ada's message with her own name as the strong chip" 'dom "$WB" | json "[c for c in d[\"chips\"] if c[\"mine\"]][0][\"text\"]" | grep -q "@Ann Example"' 'dom "$WB"'
check "the badge is gone once read" 'until_ok 20 "[ -z \"\$(dom \"$WB\" | json \"d[\\\"badge\\\"] or \\\"\\\"\")\" ]"' 'dom "$WB"; chat "$WB" state "$CID"'
check "no horizontal scrollbar in the log" 'dom "$WB" | json "d[\"scroller\"][\"wide\"]" | grep -q False' 'dom "$WB"'
shot "$WB" chat-mention-me.png
chat "$WB" type "$CID" "@Ad" >/dev/null; chat "$WB" enter "$CID" >/dev/null
chat "$WB" type "$CID" "works for me" >/dev/null
T0=$(python3 -c 'import time; print(time.time())')
chat "$WB" enter "$CID" >/dev/null
check "Ada sees Ann's reply live" 'until_ok 40 "chat \"$WA\" read \"$CID\" | grep -q \"works for me\""' 'chat "$WA" read "$CID"'
T1=$(python3 -c 'import time; print(time.time())'); echo "  reply on Ada's screen after $(python3 -c "print(round($T1-$T0,2))") s"
check "…mentioning her: the strong chip on her side" 'until_ok 20 "dom \"$WA\" | json \"[c[\\\"text\\\"] for c in d[\\\"chips\\\"] if c[\\\"mine\\\"]]\" | grep -q \"Ada Lovelace\""' 'dom "$WA"'
shot "$WA" chat-thread.png
B "$WA" ui look dark >/dev/null; sleep 1; shot "$WA" chat-thread-dark.png; B "$WA" ui look light >/dev/null
if [ "$API" = "True" ]; then
  # Ada is looking at the canvas, its chat showing, Copper in front: no pill — she sees it there.
  check "no pill for a mention you are watching" 'chat "$WA" frontmost on >/dev/null; sleep 3; chat "$WA" mentions | json "d[\"pill\"] is None and len(d[\"mentions\"]) == 0" | grep -q True' 'chat "$WA" mentions'
fi
chat "$WC" members "$CID" >/dev/null
check "Ann's other Mac reads the same thread" 'until_ok 40 "chat \"$WC\" read \"$CID\" | grep -q \"works for me\""' 'chat "$WC" read "$CID"'
check "canvas_read carries the chat" 'B "$WA" canvas read "$CID" | json "[m[\"text\"] for m in d.get(\"chat\",[])]" | grep -q "works for me"' 'B "$WA" canvas read "$CID" | head -c 600'
check "canvas_chat posts as the signed-in person" 'chat "$WC" send "$CID" "the room is booked" --mention ada | json "d.get(\"sent\")" | grep -q True' 'chat "$WC" send "$CID" again'
chat "$WB" toggle "$CID" >/dev/null   # Ann hides it; Ada keeps it showing

echo "== relaunch every world"
stop "$WA"; stop "$WB"; stop "$WC"
launch "$WA" "$PA"; launch "$WB" "$PB"; launch "$WC" "$PC"
wait_bench "$WA"; wait_bench "$WB"; wait_bench "$WC"; sleep 3
B "$WA" canvas open "$CID" >/dev/null; B "$WB" canvas open "$CID" >/dev/null
check "Ada's messages are all there after the relaunch" 'until_ok 40 "[ \"\$(chat \"$WA\" read \"$CID\" | json \"len(d[\\\"messages\\\"])\")\" = 3 ]"' 'chat "$WA" read "$CID"'
check "Ann's too" 'until_ok 40 "[ \"\$(chat \"$WB\" read \"$CID\" | json \"len(d[\\\"messages\\\"])\")\" = 3 ]"' 'chat "$WB" read "$CID"'
check "Ada's panel is still showing" 'until_ok 20 "dom \"$WA\" | json \"d[\\\"panel\\\"]\" | grep -q True"' 'dom "$WA"; chat "$WA" state "$CID"'
check "Ann's is still hidden" 'dom "$WB" | json "d[\"panel\"]" | grep -q False' 'dom "$WB"; chat "$WB" state "$CID"'
chat "$WB" key "$CID" >/dev/null
check "C shows Ann's panel from the board" 'dom "$WB" | json "d[\"panel\"]" | grep -q True' 'dom "$WB"'
chat "$WB" key "$CID" >/dev/null
check "…and hides it again" 'dom "$WB" | json "d[\"panel\"]" | grep -q False' 'dom "$WB"'
check "nothing Ann read is unread again" 'chat "$WB" state "$CID" | json "d[\"page\"][\"unread\"]" | grep -q "^0$"' 'chat "$WB" state "$CID"'
shot "$WA" chat-after-relaunch.png

echo
echo "server $SERVER · $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
