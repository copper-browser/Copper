#!/bin/bash
# Assignees on checklist rows, end to end, against one copper-cloud 0.6.0+:
# three headless probe-world Coppers of this build — Ada (world a), Grace
# (world b) and Grace's other Mac (world c, which first makes Alan, who never
# joins the canvas). An agent's canvas_apply names people by email and name;
# the text keeps one `@Name` line each and canvas_read gives their ids; the
# person newly assigned gets the pill ("assigned you"), the door's dot and a
# notification, on both her Macs; Open shows the card — not the chat — with her
# row lit, and reads it everywhere; the picker on Ada's board (a real click on
# a row's person button, then keys) lists the canvas's people and assigns with
# their id, which tells Grace again; taking someone off tells no one; a card on
# screen reads its assignment; two people assigning on one row at once both
# stick; the cloud's /read has the names.
#
#   docs/fixtures/checklist-assignees-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world, headless, on its own MCP port, and only the pids this
# script started are ever stopped. ASG_WORLD=NAME names the worlds NAMEa…NAMEc
# (default asg; world folders and pid files ignore case, so pick a NAME no
# other running world's name matches in any case), ASG_PORT=N puts them on N…N+2 (default 4351), ASG_SHOTS=DIR
# keeps pictures there (assignees-*.png).
set -uo pipefail
LINK=${1:?link code}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP=${2:-"$ROOT/build/Copper.app"}
NAME=${ASG_WORLD:-asg}
PORT=${ASG_PORT:-4351}
WA="${NAME}a"; WB="${NAME}b"; WC="${NAME}c"
PA=$PORT; PB=$((PORT + 1)); PC=$((PORT + 2))
SHOTS=${ASG_SHOTS:-}
KEY=$(python3 -c 'import sys,urllib.parse as u; f=u.urlparse(sys.argv[1]).fragment; print(dict(p.split("=",1) for p in f.split("&"))["k"])' "$LINK")
HOST=https://$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).netloc)' "$LINK")
STAMP=$(date +%s)
PW="correct-horse-battery"
ADA="ada-$STAMP@example.com"; GRACE="grace-$STAMP@example.com"; ALAN="alan-$STAMP@example.com"
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
fresh() { # world port — a new world
  local w=$1 port=$2
  stop "$w"
  rm -rf "$HOME/Library/Application Support/Copper ($w)"
  defaults delete "com.officecommun.search.test.$w" >/dev/null 2>&1 || true
  defaults write "com.officecommun.search.test.$w" bench -bool true
  defaults write "com.officecommun.search.test.$w" welcomed -bool true
  : > "/tmp/copper-$w.log"
  SEARCH_PROBE=$w SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$port SEARCH_HEADLESS_SIZE=1440x900 \
    "$APP/Contents/MacOS/Copper" >> "/tmp/copper-$w.log" 2>&1 &
  echo $! > "/tmp/copper-$w.pid"
}
B() { "$ROOT/bench" --world "$1" "${@:2}"; }
# An MCP tool call in world $1 (port $2), as an agent makes it.
call() { SEARCH_PROBE=$1 SEARCH_MCP_PORT=$2 "$APP/Contents/Resources/bin/copper" call "$3" "$4"; }
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
until_ok() { local n=$1; shift; for _ in $(seq 1 "$n"); do if eval "$1"; then return 0; fi; sleep 0.25; done; return 1; }
tab() { B "$1" canvas tabs | json "[t['tab'] for c in d['canvases'] for t in c['tabs'] if c['id']=='$CID'][0]"; }
page() { B "$1" eval "$(tab "$1")" "$2"; }
# One line per row, "Label=Name,Name", as world $1 reads the card (names sorted).
people() { B "$1" canvas read "$CID" | json "'\\n'.join(r['label'] + '=' + ','.join(sorted(a['name'] for a in r.get('assignees', []))) for s in d['shapes'] if s['id'] == 'sprint' for r in s['rows'])"; }
unread() { chat "$1" mentions | json 'len(d["mentions"])'; }
cleanup() { stop "$WA"; stop "$WB"; stop "$WC"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== launching worlds $WA $WB $WC"
fresh "$WA" "$PA"; fresh "$WB" "$PB"; fresh "$WC" "$PC"
wait_bench "$WA"; wait_bench "$WB"; wait_bench "$WC"
sleep 2

echo "== accounts and a shared canvas with Grace on it"
for w in "$WA" "$WB" "$WC"; do B "$w" cloud link "$LINK" >/dev/null; done
check "Ada signs up" 'B "$WA" cloud signup "$ADA" "$PW" "Ada Lovelace" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WA" cloud status'
check "Grace signs up" 'B "$WB" cloud signup "$GRACE" "$PW" "Grace Hopper" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WB" cloud status'
B "$WC" cloud signup "$ALAN" "$PW" "Alan Turing" >/dev/null; B "$WC" cloud signout >/dev/null
API=$(chat "$WA" mentions | json 'd.get("mentionsApi")')
SERVER=$(chat "$WA" mentions | json 'd.get("server") or ""')
echo "  server $SERVER, mentions API: $API"
[ "$API" = "True" ] || { echo "this harness needs copper-cloud 0.6.0+ (mentions)"; exit 1; }
CID=$(B "$WA" canvas create "Sprint $STAMP" | json 'd.get("id","")')
check "Ada made a shared canvas" '[ -n "$CID" ]' 'B "$WA" canvas list'
B "$WA" canvas remind "$CID" "$GRACE" >/dev/null
IB=$(B "$WB" canvas invites | json '[i["id"] for i in d["invites"] if "Sprint" in i["canvas"]][0]')
B "$WB" canvas accept "$IB" >/dev/null
check "Grace signs in on her other Mac" 'B "$WC" cloud signin "$GRACE" "$PW" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WC" cloud status'
B "$WA" canvas open "$CID" >/dev/null; sleep 1
GID=$(chat "$WA" members "$CID" | json '[m["id"] for m in d["members"] if m["name"]=="Grace Hopper"][0]')
check "Grace is one of the canvas's people" '[ -n "$GID" ]' 'chat "$WA" members "$CID"'

echo "== an agent assigns (canvas_apply)"
OPS="{\"reason\":\"e2e\",\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"sprint\",\"x\":-200,\"y\":-120,\"title\":\"Sprint\",\"columns\":[\"To do\",\"Doing\",\"Done\"],\"rows\":[\"Fix login\",\"Notes\",\"Ship\"],\"notes\":{\"Fix login\":\"Blocked on the certificate\"},\"assignees\":{\"Fix login\":[\"$GRACE\"],\"Notes\":[\"Alan Turing\"],\"Ship\":[\"Ada Lovelace\"]}}}]}"
check "canvas_apply takes assignees" 'call "$WA" "$PA" canvas_apply "$OPS" | json "d[\"applied\"]" | grep -q 1' 'call "$WA" "$PA" canvas_apply "$OPS"'
TEXT=$(B "$WA" canvas read "$CID" | json "[s['text'] for s in d['shapes'] if s['id']=='sprint'][0]")
check "the text: the comment, then one @ line per person" '[ "$TEXT" = "$(printf "### Sprint\n- [ ] Fix login\n  > Blocked on the certificate\n  @Grace Hopper\n- [ ] Notes\n  @Alan Turing\n- [ ] Ship\n  @Ada Lovelace")" ]' 'echo "$TEXT"'
READ=$(call "$WA" "$PA" canvas_read "{\"reason\":\"e2e\",\"id\":\"$CID\"}")
FIRST=$(echo "$READ" | json "[(a['name'], a.get('id'), a.get('email')) for s in d['shapes'] if s['id']=='sprint' for a in s['rows'][0]['assignees']]")
check "canvas_read: Grace, named by her email, is Grace, with her id" '[ "$FIRST" = "[('"'"'Grace Hopper'"'"', '"'"'$GID'"'"', '"'"'$GRACE'"'"')]" ]' 'echo "$FIRST"'
SECOND=$(echo "$READ" | json "[s['rows'][1]['assignees'] for s in d['shapes'] if s['id']=='sprint'][0]")
check "…Alan (not on the canvas) is a name of his own" '[ "$SECOND" = "[{'"'"'name'"'"': '"'"'Alan Turing'"'"'}]" ]' 'echo "$SECOND"'

echo "== Grace is told"
check "Grace gets the pill: Ada assigned her" 'until_ok 60 "chat \"$WB\" mentions | json \"(d.get(\\\"pill\\\") or {}).get(\\\"assignment\\\")\" | grep -q True"' 'chat "$WB" mentions'
MB=$(chat "$WB" mentions)
check "…from Ada, the row and the card as its line" 'echo "$MB" | json "d[\"pill\"][\"from\"] + \" | \" + d[\"pill\"][\"excerpt\"]" | grep -q "^Ada Lovelace | Fix login · Sprint$"' 'echo "$MB"'
check "…a dot on the Canvas door" 'echo "$MB" | json "d[\"door\"]" | grep -q mention' 'echo "$MB"'
check "…and a notification that says assigned, Copper being behind" 'echo "$MB" | json "d[\"notices\"][-1][\"title\"]" | grep -q "^Ada Lovelace assigned you$"' 'echo "$MB"'
check "Grace's other Mac has it too" 'until_ok 60 "[ \"\$(unread \"$WC\")\" = 1 ]"' 'chat "$WC" mentions'
check "Ada, assigning herself, is told nothing" '[ "$(unread "$WA")" = 0 ]' 'chat "$WA" mentions'
shot "$WB" assignees-pill.png
OPEN=$(chat "$WB" pill open)
check "Open shows the canvas" 'echo "$OPEN" | json "d[\"front\"]" | grep -q "$CID"' 'echo "$OPEN"'
check "…at the card, Grace's row lit" 'until_ok 20 "page \"$WB\" \"(() => document.querySelectorAll(\\\"[data-id=sprint] .cl-row-flash\\\").length)()\" | grep -q 1"' 'page "$WB" "document.querySelector(\"[data-id=sprint]\")?.outerHTML.slice(0, 400)"'
check "…the card on screen" 'page "$WB" "(() => { const r = document.querySelector(\"[data-id=sprint]\").getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth })()" | grep -q true' 'page "$WB" "JSON.stringify(document.querySelector(\"[data-id=sprint]\").getBoundingClientRect())"'
check "…and not the chat" 'chat "$WB" state "$CID" | json "d[\"page\"][\"open\"]" | grep -q False' 'chat "$WB" state "$CID"'
check "…and it is read" '[ "$(unread "$WB")" = 0 ]' 'chat "$WB" mentions'
check "read on Grace's other Mac too" 'until_ok 60 "[ \"\$(unread \"$WC\")\" = 0 ]"' 'chat "$WC" mentions'
check "Grace's own face is ringed" 'page "$WB" "document.querySelectorAll(\"[data-id=sprint] .cl-face-me\").length" | grep -q 1' 'page "$WB" "document.querySelector(\"[data-id=sprint] .cl-people\")?.outerHTML"'
shot "$WB" assignees-opened.png
# Grace goes to another board: Sprint's tab is behind, so what comes next waits for her.
B "$WB" canvas open personal >/dev/null

echo "== Ada assigns from the board (the picker)"
B "$WA" canvas open "$CID" >/dev/null
call "$WA" "$PA" canvas_focus "{\"reason\":\"e2e\",\"id\":\"$CID\",\"shapeIds\":[\"sprint\"]}" >/dev/null; sleep 1
P=$(B "$WA" canvas assign sprint Notes)
check "a click on Notes' person button opens the picker" 'echo "$P" | json "d[\"open\"]" | grep -q True' 'echo "$P"'
check "…headed by the canvas's people, Ada first, Grace in it" 'echo "$P" | json "d[\"heading\"] + \" | \" + \",\".join(d[\"options\"])" | grep -q "^People on this canvas | Ada Lovelace (you),Grace Hopper"' 'echo "$P"'
check "…Alan (a name on the board) after them, ticked" 'echo "$P" | json "d[\"ticked\"]" | grep -q "Alan Turing"' 'echo "$P"'
check "…its field has the keyboard" 'echo "$P" | json "d[\"focused\"]" | grep -q True' 'echo "$P"'
T=$(tab "$WA")
B "$WA" key "$T" "gra" >/dev/null; sleep 0.3
check "typing filters to Grace" '[ "$(B "$WA" canvas picker | json "d[\"options\"][0]")" = "Grace Hopper" ]' 'B "$WA" canvas picker'
shot "$WA" assignees-picker-shared.png
B "$WA" key "$T" "↩" >/dev/null; sleep 0.4
check "Return puts her on the row, with her id" 'until_ok 20 "B \"$WA\" canvas checklist sprint | json \"[a.get(\\\"id\\\") for a in d[\\\"checklists\\\"][0][\\\"rows\\\"][1][\\\"assignees\\\"]]\" | grep -q \"$GID\""' 'B "$WA" canvas checklist sprint'
B "$WA" key "$T" "⎋" >/dev/null
check "Escape closes the picker" '[ "$(B "$WA" canvas picker | json "d[\"open\"]")" = False ]' 'B "$WA" canvas picker'
check "Grace is told again" 'until_ok 60 "chat \"$WB\" mentions | json \"[m[\\\"excerpt\\\"] for m in d[\\\"mentions\\\"]]\" | grep -q \"Notes · Sprint\""' 'chat "$WB" mentions'
check "…with a notification" 'chat "$WB" mentions | json "d[\"notices\"][-1][\"body\"]" | grep -q "^Notes · Sprint$"' 'chat "$WB" mentions'
check "Grace sees herself on Notes" 'until_ok 40 "people \"$WB\" | grep -qx \"Notes=Alan Turing,Grace Hopper\""' 'people "$WB"'
# Off again: the same pick in the picker takes her off, and tells no one.
B "$WA" canvas assign sprint Notes >/dev/null; B "$WA" key "$T" "grace" >/dev/null; sleep 0.3; B "$WA" key "$T" "↩" >/dev/null; sleep 0.3; B "$WA" key "$T" "⎋" >/dev/null
check "picking her again takes her off" 'until_ok 20 "people \"$WA\" | grep -qx \"Notes=Alan Turing\""' 'people "$WA"'
sleep 3
check "…and tells no one" '[ "$(unread "$WB")" = 1 ]' 'chat "$WB" mentions'
# Grace is looking at the board already: the card on screen in her visible tab reads it.
B "$WB" canvas open "$CID" >/dev/null
call "$WB" "$PB" canvas_focus "{\"reason\":\"e2e\",\"id\":\"$CID\",\"shapeIds\":[\"sprint\"]}" >/dev/null
check "the card on Grace's screen reads her assignment" 'until_ok 60 "[ \"\$(unread \"$WB\")\" = 0 ]"' 'chat "$WB" mentions'

echo "== two people assigning on one row at the same millisecond"
# Each page adds one person to Ship at the same moment, before either can hear of the other's.
AT=$(python3 -c "import time; print(int(time.time()*1000)+3000)")
ARM='(() => { setTimeout(() => window.copperCanvas.apply(JSON.stringify({ops:[{op:"update", id:"sprint", patch:{assignees:{Ship:["Ada Lovelace", "WHO"]}}}]})), AT - Date.now()); return "armed" })()'
page "$WA" "$(echo "$ARM" | sed "s/AT/$AT/; s/WHO/Katherine Johnson/")" >/dev/null
page "$WB" "$(echo "$ARM" | sed "s/AT/$AT/; s/WHO/Grace Hopper/")" >/dev/null
python3 -c "import time; time.sleep(max(0, $AT/1000 - time.time()))"; sleep 1
check "Ada's Copper has all three on Ship" 'until_ok 40 "people \"$WA\" | grep -qx \"Ship=Ada Lovelace,Grace Hopper,Katherine Johnson\""' 'people "$WA"'
check "Grace's too" 'until_ok 40 "people \"$WB\" | grep -qx \"Ship=Ada Lovelace,Grace Hopper,Katherine Johnson\""' 'people "$WB"'

echo "== the cloud keeps the names"
B "$WA" canvas flush "$CID" >/dev/null 2>&1; sleep 2
TOK=$(curl -sk -X POST "$HOST/v1/auth/login" -H "x-copper-instance: $KEY" -H 'content-type: application/json' -d "{\"email\":\"$ADA\",\"password\":\"$PW\"}" | json 'd["token"]')
SRV=$(curl -sk "$HOST/v1/canvases/$CID/read?ids=sprint&full=true" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK" | json "d['shapes'][0]['text']")
check "cloud /read: the text has the @ lines" 'echo "$SRV" | grep -q "^  @Grace Hopper$" && echo "$SRV" | grep -q "^  @Alan Turing$"' 'echo "$SRV"'

echo
echo "server $SERVER · $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
