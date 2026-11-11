#!/bin/bash
# Checklist cards on a shared canvas, end to end, against one copper-cloud
# 0.6.0+: two headless probe-world Coppers of this build (Ada in world a,
# Grace in world b) and an older Copper (world o, default the installed
# /Applications/Copper.app). A checklist is a note in the checklist view whose
# text is the list, so the older Copper shows it as a note with task boxes:
# one-click picks through real mouse input; two people clicking different rows
# at once; new and old clients ticking different rows at the same millisecond;
# ticks crossing between card and note both ways; a note turned into a card in
# place keeping its ticks; a legacy `type:"checklist"` made through REST still
# drawn and clicked; cloud /read agrees.
#
#   docs/fixtures/checklist-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world, headless, on its own MCP port, and only the pids this
# script started are ever stopped. CKL_WORLD=NAME names the worlds NAMEa,
# NAMEb, NAMEo (default ckl), CKL_PORT=N puts them on N…N+2 (default 4302).
# OLD_APP=PATH is the older Copper (empty skips its checks). CKL_SHOTS=DIR
# keeps pictures there (checklist-*.png).
set -uo pipefail
LINK=${1:?link code}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NEW=${2:-"$ROOT/build/Copper.app"}
OLD=${OLD_APP-/Applications/Copper.app}
[ -n "$OLD" ] && [ ! -x "$OLD/Contents/MacOS/Copper" ] && { echo "no older Copper at $OLD: its checks are skipped"; OLD=""; }
NAME=${CKL_WORLD:-ckl}; PORT=${CKL_PORT:-4302}
WA="${NAME}a"; WB="${NAME}b"; WO="${NAME}o"
PA=$PORT; PB=$((PORT + 1)); PO=$((PORT + 2))
SHOTS=${CKL_SHOTS:-}
KEY=$(python3 -c 'import sys,urllib.parse as u; f=u.urlparse(sys.argv[1]).fragment; print(dict(p.split("=",1) for p in f.split("&"))["k"])' "$LINK")
HOST=https://$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).netloc)' "$LINK")
STAMP=$(date +%s); PW=correct-horse-battery
A_EMAIL=ada-$STAMP@example.com; B_EMAIL=grace-$STAMP@example.com; O_EMAIL=alan-$STAMP@example.com
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 600 || true)"; fi; }
# Poll a check for up to ~8 s (sync between worlds is fast but not instant).
settle(){ for _ in $(seq 1 16); do eval "$1" && return 0; sleep 0.5; done; return 1; }
B(){ "$ROOT/bench" --world "$1" "${@:2}"; }
J(){ python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
start(){ # world port app
  rm -rf "$HOME/Library/Application Support/Copper ($1)"
  defaults delete "com.collinrijock.copper.test.$1" >/dev/null 2>&1
  defaults write "com.collinrijock.copper.test.$1" bench -bool true
  defaults write "com.collinrijock.copper.test.$1" welcomed -bool true
  SEARCH_PROBE=$1 SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$2 SEARCH_HEADLESS_SIZE=1440x1000 "$3/Contents/MacOS/Copper" >"/tmp/copper-$1.log" 2>&1 &
  echo "$! $3" >"/tmp/copper-$1.pid"
  for _ in $(seq 1 60); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "no bench in $1"; return 1; }
stop(){ # only the pid this run started, and only while it is still that Copper
  local pid app; read -r pid app < "/tmp/copper-$1.pid" 2>/dev/null || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$app/Contents/MacOS/Copper"*) kill "$pid";; esac
  for _ in $(seq 1 40); do ps -p "$pid" >/dev/null 2>&1 || break; sleep 0.25; done
  rm -f "/tmp/copper-$1.pid"; }
trap 'stop $WA; stop $WB; stop $WO' EXIT
tab(){ B "$1" canvas tabs | J "[t['tab'] for c in d['canvases'] for t in c['tabs'] if c['id']=='$CID'][0]"; }
summary(){ B "$1" canvas checklist "$2" | J "[(r['label'], r['pick'], r.get('by')) for r in d['checklists'][0]['rows']]"; }
# A shape's text as world $1 reads it (any Copper, old or new).
text(){ B "$1" canvas read "$CID" | J "[s.get('text') for s in d['shapes'] if s['id']=='$2'][0]"; }
# The task boxes world $1 draws in note $2 (an older Copper: the note itself).
boxes(){ B "$1" eval "$2" "(() => JSON.stringify([...document.querySelectorAll('[data-id=\"$3\"][data-kind=\"sticky\"] button[role=checkbox]')].map(b => b.getAttribute('aria-checked'))))()"; }
# A real click on the Nth task box of note $3 in world $1 (tab $2), as a person clicks it.
tickbox(){ local xy; xy=$(B "$1" eval "$2" "(() => { const b = document.querySelectorAll('[data-id=\"$3\"][data-kind=\"sticky\"] button[role=checkbox]')[$4]; if (!b) return 'none'; const r = b.getBoundingClientRect(); return Math.round(r.left + r.width / 2) + ' ' + Math.round(r.top + r.height / 2) })()"); [ "$xy" = none ] && return 1; B "$1" canvas click $xy >/dev/null; }
zoom(){ B "$1" eval "$2" "(() => { window.copperCanvas.zoomTo($3); return 'ok' })()" >/dev/null; }
shot(){ [ -n "$SHOTS" ] && mkdir -p "$SHOTS" && { B "$1" drive pane off >/dev/null 2>&1; B "$1" window "$SHOTS/$2" >/dev/null 2>&1; } || true; }
TOKEN(){ curl -sk -X POST "$HOST/v1/auth/login" -H "x-copper-instance: $KEY" -H 'content-type: application/json' -d "{\"email\":\"$1\",\"password\":\"$PW\"}" | J 'd["token"]'; }
srvread(){ curl -sk "$HOST/v1/canvases/$CID/read?ids=$1&full=true" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK"; }

echo "== worlds, link, accounts"
start "$WA" "$PA" "$NEW"; start "$WB" "$PB" "$NEW"; [ -n "$OLD" ] && start "$WO" "$PO" "$OLD"; sleep 2
for w in $WA $WB ${OLD:+$WO}; do B "$w" cloud link "$LINK" >/dev/null; done
B "$WA" cloud signup "$A_EMAIL" $PW "Ada Lovelace" >/dev/null
B "$WB" cloud signup "$B_EMAIL" $PW "Grace Hopper" >/dev/null
[ -n "$OLD" ] && B "$WO" cloud signup "$O_EMAIL" $PW "Alan Turing" >/dev/null
CID=$(B "$WA" canvas create "Team dinners $STAMP" | J 'd["id"]')
check "A made a shared canvas" '[ -n "$CID" ]' 'echo none'
B "$WA" canvas open "$CID" >/dev/null; sleep 2
for e in "$B_EMAIL" ${OLD:+"$O_EMAIL"}; do
  SEARCH_PROBE=$WA SEARCH_MCP_PORT=$PA "$NEW/Contents/Resources/bin/copper" call canvas_invite "{\"reason\":\"e2e\",\"id\":\"$CID\",\"email\":\"$e\"}" >/dev/null
done; sleep 2
for w in $WB ${OLD:+$WO}; do I=$(B "$w" canvas invites | J 'd["invites"][0]["id"]'); B "$w" canvas accept "$I" >/dev/null; done
TOK=$(TOKEN "$B_EMAIL")

echo "== the toolbar's checklist tool (R) makes the note form"
TA=$(tab "$WA")
TOOL=$(B "$WA" eval "$TA" "(() => { const b = [...document.querySelectorAll('[role=toolbar] button')].find(b => (b.getAttribute('aria-label') || '').startsWith('Checklist')); if (!b) return 'none'; b.click(); return 'ok' })()")
B "$WA" canvas click 720 480 >/dev/null; sleep 1
NEWK=$(B "$WA" canvas read "$CID" | J "[(s['type'], s.get('view'), s.get('columns')) for s in d['shapes']]")
check "a click with the tool makes a sticky in the checklist view (Yes / No)" '[ "$NEWK" = "[('"'"'sticky'"'"', '"'"'checklist'"'"', ['"'"'Yes'"'"', '"'"'No'"'"'])]" ]' 'echo "$TOOL $NEWK"'
NID=$(B "$WA" canvas read "$CID" | J "d['shapes'][0]['id'] if d['shapes'] else ''")
[ -n "$NID" ] && B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"delete\",\"id\":\"$NID\"}]}" >/dev/null

echo "== agent ops on the page (canvas_apply): checklists are notes in the checklist view"
ROWS='["Ann","Bob","Cy","Dee","Eve","Fay"]'
R=$(B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"tue\",\"x\":0,\"y\":0,\"title\":\"Tue\",\"rows\":$ROWS}},{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"wed\",\"x\":360,\"y\":0,\"title\":\"Wed\",\"rows\":$ROWS,\"picks\":{\"Ann\":\"yes\"}}},{\"op\":\"add\",\"shape\":{\"type\":\"checklist\",\"id\":\"going\",\"x\":720,\"y\":0,\"title\":\"Going\",\"columns\":[\"Going\"],\"rows\":[\"Ann\",\"Ada Lovelace\",\"Bob\"],\"picks\":{\"Ada Lovelace\":true}}}],\"as\":{\"id\":\"agent:planner\",\"name\":\"Planner\"}}")
check "canvas_apply adds three checklists" '[ "$(echo "$R" | J "d[\"applied\"]")" = 3 ]' 'echo "$R"'
KIND=$(B "$WA" canvas read "$CID" | J "sorted((s['id'], s['type'], s.get('view')) for s in d['shapes'])")
check "each is a sticky with view checklist" '[ "$KIND" = "[('"'"'going'"'"', '"'"'sticky'"'"', '"'"'checklist'"'"'), ('"'"'tue'"'"', '"'"'sticky'"'"', '"'"'checklist'"'"'), ('"'"'wed'"'"', '"'"'sticky'"'"', '"'"'checklist'"'"')]" ]' 'echo "$KIND"'
check "the going note's text is the list" '[ "$(text "$WA" going)" = "$(printf "### Going\n- [ ] Ann\n- [x] Ada Lovelace\n- [ ] Bob")" ]' 'text "$WA" going'
for w in $WA $WB; do B "$w" canvas open "$CID" >/dev/null; done; sleep 3
TA=$(tab "$WA"); TB=$(tab "$WB")
for p in "$WA $TA" "$WB $TB"; do set -- $p; zoom "$1" "$2" "['tue','wed','going']"; done; sleep 1.2
check "B reads the agent's pick" 'summary "$WB" wed | grep -q "(.Ann., .Yes., .Planner.)"' 'summary "$WB" wed'

echo "== real clicks in both worlds at once (different rows)"
( for r in Ann Cy Eve; do B "$WA" canvas check tue Yes $r >/dev/null; done ) & P1=$!
( for r in Bob Dee Fay; do B "$WB" canvas check tue No $r >/dev/null; done ) & P2=$!
wait $P1 $P2; sleep 1.5
WANT="[('Ann', 'Yes', 'Ada Lovelace'), ('Bob', 'No', 'Grace Hopper'), ('Cy', 'Yes', 'Ada Lovelace'), ('Dee', 'No', 'Grace Hopper'), ('Eve', 'Yes', 'Ada Lovelace'), ('Fay', 'No', 'Grace Hopper')]"
check "A has every click" 'settle "[ \"\$(summary $WA tue)\" = \"$WANT\" ]"' 'summary "$WA" tue'
check "B has every click" 'settle "[ \"\$(summary $WB tue)\" = \"$WANT\" ]"' 'summary "$WB" tue'
check "the note's text has every click" '[ "$(text "$WB" tue)" = "$(printf "### Tue\n- [x] Ann · Yes\n- [x] Bob · No\n- [x] Cy · Yes\n- [x] Dee · No\n- [x] Eve · Yes\n- [x] Fay · No")" ]' 'text "$WB" tue'
check "one click left the card unselected" '[ "$(B "$WA" canvas read "$CID" | J "d[\"selection\"]")" = "[]" ]' 'B "$WA" canvas read "$CID" | head -c 200'
UNDO=$(B "$WA" canvas check tue Yes Ann | J 'd["checked"]')
check "a second click clears the pick" '[ "$UNDO" = False ]' 'echo $UNDO'
B "$WA" canvas check tue Yes Ann >/dev/null
B "$WA" canvas check going Going Ann >/dev/null
STRUCK=$(B "$WA" eval "$TA" "(() => [...document.querySelectorAll('[data-id=\"going\"] .cl-label-text, [data-id=\"tue\"] .cl-label-text')].map(t => getComputedStyle(t).textDecorationLine).join(','))()")
check "ticked labels are never struck through (one column or several)" '[ -n "$STRUCK" ] && ! echo "$STRUCK" | grep -q line-through' 'echo "$STRUCK"'

echo "== the same millisecond: new clients and an older one, different rows"
if [ -n "$OLD" ]; then
  B "$WO" canvas open "$CID" >/dev/null; sleep 3
  TO=$(tab "$WO"); zoom "$WO" "$TO" "['tue','wed','going']"; sleep 1
fi
AT=$(python3 -c "import time; print(int(time.time()*1000)+3000)")
CARD='(() => { const at = AT; setTimeout(() => { for (const r of ROWS) document.querySelector(`[data-id="wed"] [data-row="${r}"][data-col="COL"]`).click() }, at - Date.now()); return "armed" })()'
B "$WA" eval "$TA" "$(echo "$CARD" | sed "s/AT/$AT/; s/ROWS/['t1','t3']/; s/COL/Yes/")" >/dev/null
B "$WB" eval "$TB" "$(echo "$CARD" | sed "s/AT/$AT/; s/ROWS/['t2','t4']/; s/COL/No/")" >/dev/null
if [ -n "$OLD" ]; then
  # The older Copper ticks Fay's box in the note (index 5) at the same millisecond.
  B "$WO" eval "$TO" "(() => { const at = $AT; setTimeout(() => document.querySelectorAll('[data-id=\"wed\"][data-kind=\"sticky\"] button[role=checkbox]')[5].click(), at - Date.now()); return 'armed' })()" >/dev/null
  WANT2="[('Ann', 'Yes', 'Planner'), ('Bob', 'Yes', 'Ada Lovelace'), ('Cy', 'No', 'Grace Hopper'), ('Dee', 'Yes', 'Ada Lovelace'), ('Eve', 'No', 'Grace Hopper'), ('Fay', 'Yes', None)]"
  WTEXT=$(printf "### Wed\n- [x] Ann · Yes\n- [x] Bob · Yes\n- [x] Cy · No\n- [x] Dee · Yes\n- [x] Eve · No\n- [x] Fay")
else
  WANT2="[('Ann', 'Yes', 'Planner'), ('Bob', 'Yes', 'Ada Lovelace'), ('Cy', 'No', 'Grace Hopper'), ('Dee', 'Yes', 'Ada Lovelace'), ('Eve', 'No', 'Grace Hopper'), ('Fay', None, None)]"
  WTEXT=$(printf "### Wed\n- [x] Ann · Yes\n- [x] Bob · Yes\n- [x] Cy · No\n- [x] Dee · Yes\n- [x] Eve · No\n- [ ] Fay")
fi
python3 -c "import time; time.sleep(max(0, $AT/1000 - time.time()))"; sleep 2.5
check "A: every pick, same millisecond" 'settle "[ \"\$(summary $WA wed)\" = \"$WANT2\" ]"' 'summary "$WA" wed'
check "B: every pick, same millisecond" 'settle "[ \"\$(summary $WB wed)\" = \"$WANT2\" ]"' 'summary "$WB" wed'
check "cloud /read: the note's text has every pick" '[ "$(srvread wed | J "d[\"shapes\"][0][\"text\"]")" = "$WTEXT" ]' 'srvread wed | head -c 600'
shot "$WB" checklist-light.png
B "$WB" ui look dark >/dev/null; sleep 1; shot "$WB" checklist-dark.png; B "$WB" ui look light >/dev/null

if [ -n "$OLD" ]; then
  echo "== the older Copper: the same cards as notes with task boxes"
  check "old client reads the note's text, every pick in it" '[ "$(text "$WO" wed)" = "$WTEXT" ]' 'text "$WO" wed'
  check "old client draws the Yes/No card as a note with six boxes, all ticked" '[ "$(boxes "$WO" "$TO" wed)" = "[\"true\",\"true\",\"true\",\"true\",\"true\",\"true\"]" ]' 'boxes "$WO" "$TO" wed'
  check "old client draws the Going card as a note: Ann (new tick), Ada (agent's), Bob" 'settle "[ \"\$(boxes $WO $TO going)\" = '"'"'[\"true\",\"true\",\"false\"]'"'"' ]"' 'boxes "$WO" "$TO" going'
  shot "$WO" checklist-old-client.png
  echo "== ticks cross both ways"
  B "$WA" canvas check going Going Ann >/dev/null
  check "a new client's click shows on the old client's note" 'settle "[ \"\$(boxes $WO $TO going)\" = '"'"'[\"false\",\"true\",\"false\"]'"'"' ]"' 'boxes "$WO" "$TO" going'
  tickbox "$WO" "$TO" going 2
  check "the old client's real click shows on the new clients' card" 'settle "summary $WA going | grep -q \"(.Bob., .Going., None)\"" && settle "summary $WB going | grep -q \"(.Bob., .Going., None)\""' 'summary "$WA" going'
  tickbox "$WO" "$TO" wed 2
  check "the old client unticking Cy · No clears Cy's pick on the card" 'settle "summary $WA wed | grep -q \"(.Cy., None, None)\""' 'summary "$WA" wed; text "$WA" wed'
  B "$WB" canvas check wed No Cy >/dev/null
  check "and the new client's pick shows on the old client again" 'settle "[ \"\$(boxes $WO $TO wed)\" = '"'"'[\"true\",\"true\",\"true\",\"true\",\"true\",\"true\"]'"'"' ]" && text "$WO" wed | grep -q "Cy · No"' 'text "$WO" wed'

  echo "== a note becomes a card in place, ticks kept"
  NOTE=$(printf "### Thu\n- [ ] Ann\n- [x] Bob\n- [ ] Cy")
  ADD=$(python3 -c 'import json,sys; print(json.dumps(dict(id=sys.argv[1], ops=[dict(op="add", shape=dict(type="sticky", id="thu", x=0, y=420, w=240, h=200, text=sys.argv[2]))])))' "$CID" "$NOTE")
  OR=$(B "$WO" canvas apply "$ADD")
  check "old client adds a plain note with a heading and a task list" '[ "$(echo "$OR" | J "d[\"applied\"]")" = 1 ]' 'echo "$OR"'
  sleep 1; tickbox "$WO" "$TO" thu 2
  BEFORE=$(printf "### Thu\n- [ ] Ann\n- [x] Bob\n- [x] Cy")
  check "and ticks Cy in it" 'settle "[ \"\$(text $WA thu)\" = \"$BEFORE\" ]"' 'text "$WA" thu'
  VR=$(B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"update\",\"id\":\"thu\",\"patch\":{\"view\":\"checklist\",\"columns\":[\"Yes\",\"No\"]}}]}")
  check "update {view:checklist, columns} applies" '[ "$(echo "$VR" | J "d[\"applied\"]")" = 1 ]' 'echo "$VR"'
  sleep 1.5
  check "the text is untouched" '[ "$(text "$WB" thu)" = "$BEFORE" ]' 'text "$WB" thu'
  check "the card keeps the ticks (a tick without a suffix is Yes)" 'settle "[ \"\$(summary $WB thu)\" = \"[('"'"'Ann'"'"', None, None), ('"'"'Bob'"'"', '"'"'Yes'"'"', None), ('"'"'Cy'"'"', '"'"'Yes'"'"', None)]\" ]"' 'summary "$WB" thu'
  B "$WB" canvas check thu No Ann >/dev/null
  check "a pick on the new card reaches the old client's note" 'settle "text $WO thu | grep -q \"Ann · No\"" && settle "[ \"\$(boxes $WO $TO thu)\" = '"'"'[\"true\",\"true\",\"true\"]'"'"' ]"' 'text "$WO" thu'
  B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"update\",\"id\":\"thu\",\"patch\":{\"view\":null}}]}" >/dev/null; sleep 1.5
  check "view:null makes it a plain note again, text kept" '[ -z "$(B "$WB" canvas read "$CID" | J "[s.get(\"view\") or \"\" for s in d[\"shapes\"] if s[\"id\"]==\"thu\"][0]")" ] && text "$WB" thu | grep -q "Ann · No" && [ "$(boxes "$WB" "$TB" thu)" = "[\"true\",\"true\",\"true\"]" ]' 'B "$WB" canvas read "$CID" | head -c 400'
  B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"update\",\"id\":\"thu\",\"patch\":{\"view\":\"checklist\"}}]}" >/dev/null
fi

if [ -n "$SHOTS" ]; then
  for p in "$WA $TA" "$WB $TB"; do set -- $p; zoom "$1" "$2" "['going']"; done; sleep 1.2; shot "$WB" checklist-going.png
  zoom "$WB" "$TB" "['wed']"; sleep 1.2; shot "$WB" checklist-yesno.png
  if [ -n "$OLD" ]; then zoom "$WO" "$TO" "['wed']"; sleep 1.2; shot "$WO" checklist-yesno-old-client.png
    zoom "$WO" "$TO" "['going']"; sleep 1.2; shot "$WO" checklist-going-old-client.png; fi
fi

echo "== a legacy type:\"checklist\" from REST /ops is still drawn and clicked"
LR=$(curl -sk -X POST "$HOST/v1/canvases/$CID/ops" -H "x-copper-instance: $KEY" -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
  -d '{"as":{"id":"agent:helper","name":"Helper"},"ops":[{"op":"add","shape":{"type":"checklist","id":"legacy","x":1080,"y":0,"title":"Fri","rows":["Ann","Bob"],"picks":{"Ann":"Yes"}}}]}')
check "REST adds a legacy checklist" '[ "$(echo "$LR" | J "d[\"applied\"]")" = 1 ]' 'echo "$LR"'
check "new clients draw it" 'settle "summary $WA legacy | grep -q \"(.Ann., .Yes., .Helper.)\""' 'summary "$WA" legacy'
B "$WA" canvas check legacy No Bob >/dev/null
check "and a click on it reaches the cloud" 'settle "srvread legacy | J \"[(r[\\\"label\\\"], r[\\\"pick\\\"]) for r in d[\\\"shapes\\\"][0][\\\"rows\\\"]]\" | grep -q \"(.Bob., .No.)\""' 'srvread legacy | head -c 500'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
