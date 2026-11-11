#!/bin/bash
# Two headless probe-world Coppers against one copper-cloud: link, accounts,
# sync both ways, a shared canvas with an invite, live collaboration, agent ops,
# invites on both ends (pending, reminders, withdraw, accept), a stale invite
# after a share-link join, and a history push that holds an address too big for
# the cloud.
#
#   docs/fixtures/cloud-e2e.sh "<link code>" [app-path]
#
# Never touches the browser somebody is using: every instance runs with its
# own SEARCH_PROBE world (clouda/cloudb/cloudc/cloudd), headless, on its own MCP
# port. E2E_WORLD=NAME names them NAMEa…NAMEd and E2E_PORT=N puts them on
# N…N+3 (default cloud, 4171). E2E_SHOTS=DIR keeps pictures of the Share sheet
# and the invite pill there. Reminder and withdraw checks run on copper-cloud
# 0.5.0 and later; an older cloud gets the checks for how Copper degrades.
set -euo pipefail
LINK=${1:?link code}
LINK_B=${LINK_B:-$LINK}   # directory-mode instances: a second access key for world B
LINK_D=${LINK_D:-$LINK}   # …and one for world D (history)
APP=${2:-"$(cd "$(dirname "$0")/../.." && pwd)/build/Copper.app"}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=${E2E_WORLD:-cloud}; PORT=${E2E_PORT:-4171}
WA=${W}a; WB=${W}b; WC=${W}c; WD=${W}d
PA=$PORT; PB=$((PORT+1)); PC=$((PORT+2)); PD=$((PORT+3))
SHOTS=${E2E_SHOTS:-}
# https://HOST:PORT of the cloud, from the link code (copper-cloud://HOST:PORT/#k=…&fp=…)
HOSTPORT=$(python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).netloc)' "$LINK")
HOST="https://$HOSTPORT"
STAMP=$(date +%s)
A_EMAIL="a-$STAMP@example.com"; B_EMAIL="b-$STAMP@example.com"; PW="correct-horse-battery"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
# check NAME CONDITION WHAT-TO-SHOW: CONDITION is eval'd; on failure WHAT-TO-SHOW runs
# and its first lines are printed beside the name.
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 1200 || true)"; fi; }

# Stop the probe this run started for world $1 — only if that pid is still
# this build's Copper (a stale pid file never kills anything else).
stop() {
  local pid; pid=$(cat "/tmp/copper-$1.pid" 2>/dev/null) || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$APP/Contents/MacOS/Copper"*) kill "$pid" 2>/dev/null || true ;; esac
  rm -f "/tmp/copper-$1.pid"
}
world() { # world port [seed-function]
  local w=$1 port=$2
  stop "$w"
  lsof -tnP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 1
  rm -rf "$HOME/Library/Application Support/Copper ($w)"
  defaults delete "com.collinrijock.copper.test.$w" >/dev/null 2>&1 || true
  defaults write "com.collinrijock.copper.test.$w" bench -bool true
  defaults write "com.collinrijock.copper.test.$w" welcomed -bool true
  if [ -n "${3:-}" ]; then mkdir -p "$HOME/Library/Application Support/Copper ($w)"; "$3" "$w"; fi
  SEARCH_PROBE=$w SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$port SEARCH_HEADLESS_SIZE=1440x1000 \
    "$APP/Contents/MacOS/Copper" > "/tmp/copper-$w.log" 2>&1 &
  echo $! > "/tmp/copper-$w.pid"
}
B() { "$ROOT/bench" --world "$1" "${@:2}"; }  # bench in a world
wait_bench() { for _ in $(seq 1 60); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "bench never answered in $1"; return 1; }
json() { python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: d={'raw': raw.strip()}
try: print($1)
except Exception as e: print('')"; }

echo "== launching worlds"
world "$WA" "$PA"; world "$WB" "$PB"
wait_bench "$WA"; wait_bench "$WB"
sleep 2

set +e
echo "== link + accounts"
B "$WA" cloud link "$LINK" | json '"linked" if d.get("linked") else d'
B "$WB" cloud link "$LINK_B" | json '"linked" if d.get("linked") else d'
check "A signs up" 'B "$WA" cloud signup "$A_EMAIL" "$PW" "Alice" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WA" cloud status'
check "B signs up" 'B "$WB" cloud signup "$B_EMAIL" "$PW" "Bob" | json "d.get(\"signedIn\")" | grep -q True' 'B "$WB" cloud status'
check "wrong password refused" '{ B "$WB" cloud signin "$B_EMAIL" wrong-password-here 2>&1 || true; } | grep -qi "wrong email or password"' 'true'
B "$WB" cloud signin "$B_EMAIL" "$PW" >/dev/null

echo "== sync: bookmarks + spaces A → B (same account on both)"
B "$WB" cloud signout >/dev/null; B "$WB" cloud signin "$A_EMAIL" "$PW" >/dev/null
echo "== privacy: with sync off, the Personal canvas stays on this Mac"
B "$WA" canvas open personal >/dev/null; sleep 2
B "$WA" canvas apply "{\"id\":\"personal\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"private $STAMP\"}}]}" >/dev/null; sleep 4
B "$WB" canvas open personal >/dev/null; sleep 4
check "Personal content does not reach B while canvas sync is off" '! B "$WB" canvas read personal | grep -q "private $STAMP"' 'B "$WB" canvas read personal | head -c 300'
B "$WA" cloud sync on all >/dev/null; B "$WB" cloud sync on all >/dev/null
sleep 6
check "Personal content reaches B once canvas sync is on" 'B "$WB" canvas read personal | grep -q "private $STAMP"' 'B "$WB" canvas read personal | head -c 300'
B "$WA" cloud bookmark "https://example.com/e2e-$STAMP" "E2E bookmark" >/dev/null
B "$WA" cloud sync now >/dev/null; sleep 3; B "$WB" cloud sync now >/dev/null; sleep 2
check "bookmark reaches B" 'B "$WB" cloud doc bookmarks | grep -q "e2e-$STAMP"' 'B "$WB" cloud log | tail -5'
B "$WA" cloud pin "https://example.org/pinned-$STAMP" >/dev/null || true
B "$WA" cloud sync now >/dev/null; sleep 3; B "$WB" cloud sync now >/dev/null; sleep 2
check "pinned tab reaches B" 'B "$WB" cloud doc spaces | grep -q "pinned-$STAMP"' 'B "$WB" cloud log | tail -5'
check "A sees B as another device" 'B "$WA" cloud devices | grep -qi "$WB\|device"' 'B "$WA" cloud devices'

echo "== canvas: shared canvas, invite, live collaboration, agent ops"
B "$WB" cloud signout >/dev/null; B "$WB" cloud signin "$B_EMAIL" "$PW" >/dev/null
CREATE=$(B "$WA" canvas create "Roadmap $STAMP"); echo "$CREATE" | head -c 300; echo
CID=$(echo "$CREATE" | json 'd.get("id") or (d.get("canvas") or {}).get("id") or ""')
check "A created a shared canvas" '[ -n "$CID" ]' 'echo "$CREATE"'
B "$WA" canvas open "$CID" >/dev/null; sleep 2
INV=$(B "$WA" canvas apply "{\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"from A $STAMP\",\"x\":0,\"y\":0}}]}" 2>&1); echo "$INV" | head -c 200; echo
# invite through the tool surface (copper CLI) so the MCP path is exercised too
export SEARCH_PROBE=$WA SEARCH_MCP_PORT=$PA
CLI="$APP/Contents/Resources/bin/copper"
cli() { for _ in 1 2 3 4 5; do if out=$("$CLI" "$@" 2>&1); then echo "$out"; return 0; fi; sleep 2; done; echo "$out"; return 1; }
cli call canvas_invite "{\"reason\":\"e2e\",\"id\":\"$CID\",\"email\":\"$B_EMAIL\"}" | head -c 300; echo
unset SEARCH_PROBE SEARCH_MCP_PORT
sleep 2
INVITES=$(B "$WB" canvas invites); echo "$INVITES" | head -c 300; echo
IID=$(echo "$INVITES" | json 'd["invites"][0]["id"]')
check "B has a pending invite" '[ -n "$IID" ]' 'echo "$INVITES"'
B "$WB" canvas accept "$IID" | head -c 200; echo
B "$WB" canvas open "$CID" >/dev/null; sleep 4
check "B sees A's sticky" 'B "$WB" canvas read "$CID" | grep -q "from A $STAMP"' 'B "$WB" canvas read "$CID" | head -c 400'
export SEARCH_PROBE=$WB SEARCH_MCP_PORT=$PB
cli call canvas_apply "{\"reason\":\"e2e\",\"id\":\"$CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"from B agent $STAMP\",\"x\":300,\"y\":0}}]}" | head -c 200; echo
unset SEARCH_PROBE SEARCH_MCP_PORT
sleep 4
check "A sees B's agent sticky live" 'B "$WA" canvas read "$CID" | grep -q "from B agent $STAMP"' 'B "$WA" canvas read "$CID" | head -c 400'
check "Personal canvas is listed and not shareable" 'B "$WA" canvas list | grep -qi personal' 'B "$WA" canvas list'
B "$WA" canvas ui picture /tmp/cloud-e2e-canvas-door.png >/dev/null 2>&1 || true
B "$WA" cloud picture /tmp/cloud-e2e-settings.png >/dev/null 2>&1 || true
B "$WA" shot /tmp/cloud-e2e-canvas-a.png >/dev/null 2>&1 || true

echo "== persistence: relaunch A, Personal canvas content survives"
B "$WA" canvas open personal >/dev/null; sleep 2
B "$WA" canvas apply "{\"id\":\"personal\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"persist $STAMP\"}}]}" >/dev/null; sleep 2
stop "$WA"; sleep 3
SEARCH_PROBE=$WA SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$PA "$APP/Contents/MacOS/Copper" > "/tmp/copper-$WA.log" 2>&1 & echo $! > "/tmp/copper-$WA.pid"
wait_bench "$WA"; sleep 2; B "$WA" canvas open personal >/dev/null; sleep 3
check "Personal canvas survives relaunch" 'B "$WA" canvas read personal | grep -q "persist $STAMP"' 'B "$WA" canvas read personal | head -c 300'
check "A is still signed in after relaunch" 'B "$WA" cloud status | json "d.get(\"signedIn\")" | grep -q True' 'B "$WA" cloud status'


echo "== pairing: A mints a one-time code, a fresh world C joins with it"
world "$WC" "$PC"; wait_bench "$WC"; sleep 2
PAIR=$(B "$WA" cloud pairing-code); echo "$PAIR" | head -c 200; echo
PLINK=$(echo "$PAIR" | json 'd.get("link") or d.get("code") or ""')
check "A minted a pairing code" '[ -n "$PLINK" ]' 'echo "$PAIR"'
B "$WC" cloud pair "$PLINK" | head -c 200; echo
check "C is linked and signed in as A via the pairing code" 'B "$WC" cloud status | json "d.get(\"signedIn\") and d.get(\"email\")" | grep -q "$A_EMAIL"' 'B "$WC" cloud status'
check "the pairing code works only once" '{ B "$WC" cloud pair "$PLINK" 2>&1 || true; } | grep -qi "error\|used\|pairing"' 'true'
stop "$WC"

echo "== canvas share links: join, live presence, reset, landing page, directory"
LINK_CREATE=$(B "$WA" canvas create "Link Roadmap $STAMP"); echo "$LINK_CREATE" | head -c 300; echo
LINK_CID=$(echo "$LINK_CREATE" | json 'd.get("id") or (d.get("canvas") or {}).get("id") or ""')
check "A created a link-shared canvas" '[ -n "$LINK_CID" ]' 'echo "$LINK_CREATE"'
B "$WA" canvas open "$LINK_CID" >/dev/null; sleep 2
B "$WA" canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"link from A $STAMP\",\"x\":40,\"y\":40}}]}" >/dev/null
SHARE=$(B "$WA" canvas link "$LINK_CID"); echo "$SHARE" | head -c 500; echo
INVITE_LINK=$(echo "$SHARE" | json 'd.get("link") or ""')
WEB_LINK=$(echo "$SHARE" | json 'd.get("webLink") or ""')
check "canvas link returns copper and web links" 'echo "$INVITE_LINK" | grep -q "^copper://canvas/join/" && echo "$WEB_LINK" | grep -q "^$HOST/join/" && echo "$INVITE_LINK" | grep -q "$HOSTPORT"' 'echo "$SHARE"'
check "B is not invited before joining" '! B "$WB" canvas list | grep -q "$LINK_CID"' 'B "$WB" canvas list | head -c 500'
B "$WB" canvas join "$INVITE_LINK" | head -c 300; echo; sleep 6
check "B joins from copper invite as editor" 'B "$WB" canvas list | grep -q "$LINK_CID" && B "$WB" canvas list | grep -q editor' 'B "$WB" canvas list | head -c 600'
B "$WB" canvas open "$LINK_CID" >/dev/null; sleep 4
check "B reads A sticky after link join" 'B "$WB" canvas read "$LINK_CID" | grep -q "link from A $STAMP"' 'B "$WB" canvas read "$LINK_CID" | head -c 500'
B "$WA" canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"live from A $STAMP\",\"x\":280,\"y\":40}}]}" >/dev/null; sleep 4
check "A edits arrive live at B" 'B "$WB" canvas read "$LINK_CID" | grep -q "live from A $STAMP"' 'B "$WB" canvas read "$LINK_CID" | head -c 600'
B "$WB" canvas apply "{\"id\":\"$LINK_CID\",\"ops\":[{\"op\":\"add\",\"shape\":{\"type\":\"sticky\",\"text\":\"live from B $STAMP\",\"x\":520,\"y\":40}}]}" >/dev/null; sleep 4
check "B edits arrive live at A" 'B "$WA" canvas read "$LINK_CID" | grep -q "live from B $STAMP"' 'B "$WA" canvas read "$LINK_CID" | head -c 600'
# Drive real pointermove events through the page bridge so native presence reports a cursor.
ATAB=$(B "$WA" canvas tabs "$LINK_CID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("canvases") or [{}])[0].get("tabs", [{}])[0].get("tab", ""))')
BTAB=$(B "$WB" canvas tabs "$LINK_CID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("canvases") or [{}])[0].get("tabs", [{}])[0].get("tab", ""))')
check "A and B canvas tabs are addressable" '[ -n "$ATAB" ] && [ -n "$BTAB" ]' 'B "$WA" tabs; B "$WB" tabs'
B "$WA" eval "$ATAB" "(() => { const b=document.querySelector('[role=application]'); if (!b) return false; for (const [x,y] of [[120,140],[280,220],[420,300]]) b.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x,clientY:y,pointerId:1,pointerType:'mouse'})); return true })()" >/dev/null; sleep 4
check "B sees A named human cursor" 'B "$WB" canvas presence "$LINK_CID" | json "any(p.get(\"name\")==\"Alice\" and p.get(\"kind\")==\"human\" and p.get(\"cursor\") is not None for p in d.get(\"people\",[]))" | grep -q True' 'B "$WB" canvas presence "$LINK_CID"'
B "$WB" eval "$BTAB" "(() => { const b=document.querySelector('[role=application]'); if (!b) return false; for (const [x,y] of [[180,160],[340,240],[500,320]]) b.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:x,clientY:y,pointerId:2,pointerType:'mouse'})); return true })()" >/dev/null; sleep 4
check "A sees B named human cursor" 'B "$WA" canvas presence "$LINK_CID" | json "any(p.get(\"name\")==\"Bob\" and p.get(\"kind\")==\"human\" and p.get(\"cursor\") is not None for p in d.get(\"people\",[]))" | grep -q True' 'B "$WA" canvas presence "$LINK_CID"'
B "$WB" canvas join "$INVITE_LINK" >/dev/null; sleep 3
check "joining the same link is idempotent" 'B "$WB" canvas list | python3 -c "import json,sys; rows=json.load(sys.stdin).get(\"canvases\",[]); x=[r for r in rows if r.get(\"id\")==\"$LINK_CID\"]; print(len(x)==1 and x[0].get(\"role\")==\"editor\")" | grep -q True' 'B "$WB" canvas list | head -c 700'
B "$WB" canvas join "$WEB_LINK" >/dev/null; sleep 3
check "web invite form also opens in Copper" 'B "$WB" canvas list | grep -q "$LINK_CID"' 'B "$WB" canvas list | head -c 500'
# Use the documented auth API for the owner reset and the people directory checks.
KEY=$(python3 -c 'from urllib.parse import urlparse,parse_qs; import sys; print(parse_qs(urlparse(sys.argv[1]).fragment)["k"][0])' "$LINK")
H="X-Copper-Instance: $KEY"
ATOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"$A_EMAIL\",\"password\":\"$PW\",\"device\":{\"name\":\"e2e-reset\"}}" "$HOST/v1/auth/login" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
BTOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"$B_EMAIL\",\"password\":\"$PW\",\"device\":{\"name\":\"e2e-directory\"}}" "$HOST/v1/auth/login" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
TOKEN=$(python3 -c 'from urllib.parse import urlparse; import sys; print(urlparse(sys.argv[1]).path.rstrip("/").split("/")[-1])' "$INVITE_LINK")
LANDING=$(mktemp /tmp/copper-join.XXXXXX); LANDING_HEADERS=$(mktemp /tmp/copper-join-headers.XXXXXX)
curl -ksS -D "$LANDING_HEADERS" -o "$LANDING" "$HOST/join/$TOKEN"
check "join landing page is an HTML handoff" 'grep -q "Open this canvas in Copper" "$LANDING" && grep -qi "^cache-control: no-store" "$LANDING_HEADERS" && grep -qi "^referrer-policy: no-referrer" "$LANDING_HEADERS"' 'cat "$LANDING_HEADERS"; head -c 500 "$LANDING"'
check "join landing page reveals no canvas name" '! grep -q "Link Roadmap $STAMP" "$LANDING"' 'cat "$LANDING"'
check "B people directory lists A" 'curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/people?q=Alice" | grep -q "Alice"' 'curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/people?q=Alice"'
DELETE_STATUS=$(curl -ksS -o /dev/null -w '%{http_code}' -X DELETE -H "$H" -H "Authorization: Bearer $ATOKEN" "$HOST/v1/canvases/$LINK_CID/links")
check "owner reset revokes every share link" '[ "$DELETE_STATUS" = 204 ]' "echo reset status $DELETE_STATUS"
C_TOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"c-$STAMP@example.com\",\"password\":\"$PW\",\"display_name\":\"Charlie\",\"device\":{\"name\":\"e2e-third\"}}" "$HOST/v1/auth/signup" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token", ""))')
OLD_JOIN=$(curl -ksS -o /tmp/copper-old-join.json -w '%{http_code}' -X POST -H "$H" -H "Authorization: Bearer $C_TOKEN" "$HOST/v1/canvas-links/$TOKEN/join")
check "revoked link rejects a third account" '[ "$OLD_JOIN" = 404 ] && grep -q "link_not_found" /tmp/copper-old-join.json' 'cat /tmp/copper-old-join.json'
rm -f "$LANDING" "$LANDING_HEADERS"
# Keep both tabs present for the native visual pass; open Share on A and capture B presence.
B "$WA" canvas ui mode share "$LINK_CID" >/dev/null; B "$WA" canvas ui open >/dev/null; sleep 2
"$ROOT/bench" --world "$WA" window /tmp/wave-share-A.png >/dev/null 2>&1 || true
"$ROOT/bench" --world "$WB" window /tmp/wave-presence-B.png >/dev/null 2>&1 || true

echo "== invites: pending on both ends, a reminder at most every 30 s, withdraw, accept"
# q EXPR: EXPR over the JSON on stdin as d; E is the environment, L(x) a list of invites.
q() { python3 -c "
import sys,json,os
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: d={'raw': raw.strip()}
E=os.environ
def L(x): return x if isinstance(x,list) else (x.get('invites') or x.get('pending') or [])
try: print($1)
except Exception as e: print('')"; }
export B_EMAIL
VERSION=$(curl -ksS -H "$H" "$HOST/v1/info" | q 'd.get("version","")')
REMIND=$(python3 -c 'import sys; v=(sys.argv[1] or "0").split(".")+["0","0"]; print("yes" if tuple(int(x) for x in v[:3]) >= (0,5,0) else "no")' "$VERSION" 2>/dev/null || echo no)
echo "  copper-cloud $VERSION — reminders and withdraw: $REMIND"
# Pictures for E2E_SHOTS: a world's window (the agent pane folded away), or its Canvas card.
shot() { [ -n "$SHOTS" ] && mkdir -p "$SHOTS" && { B "$1" drive pane off >/dev/null 2>&1; "$ROOT/bench" --world "$1" window "$SHOTS/$2" >/dev/null 2>&1; } || true; }
card() { [ -n "$SHOTS" ] && mkdir -p "$SHOTS" && B "$1" canvas ui picture "$SHOTS/$2" >/dev/null 2>&1 || true; }
INV_CID=$(B "$WA" canvas create "Invites $STAMP" | q 'd.get("id") or (d.get("canvas") or {}).get("id") or ""'); export INV_CID
check "A created a canvas to invite B to" '[ -n "$INV_CID" ]' 'B "$WA" canvas list | head -c 400'
# What B's side shows: GET /v1/invites (the invite, as JSON, or nothing), the pill, the Invitations list.
b_invite() { curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/invites" | q 'next((json.dumps(i) for i in L(d) if i.get("canvas_id")==E["INV_CID"]), "")'; }
b_pill() { B "$WB" canvas pill | q '(d.get("pill") or {}).get("canvasId","") + "|" + ((d.get("pill") or {}).get("nudgedAt") or "")'; }
b_listed() { B "$WB" canvas invites | q 'any(i.get("canvasId")==E["INV_CID"] for i in d.get("invites",[]))'; }
upto() { local n=$(( ${2:-10} * 2 )); for _ in $(seq 1 "$n"); do eval "$1" && return 0; sleep 0.5; done; return 1; }
B "$WA" canvas ui mode share "$INV_CID" >/dev/null; B "$WA" canvas ui open >/dev/null; sleep 2
B "$WA" canvas ui share type "$B_EMAIL" >/dev/null; sleep 1
SHEET=$(B "$WA" canvas ui share invite "$B_EMAIL" --instant); INVITED_AT=$(date +%s)
ROW=$(echo "$SHEET" | q '",".join(r.get("state","") for r in d.get("people",[]) + [d.get("typedRow") or {}] + d.get("pending",[]) if r.get("email","").lower()==E["B_EMAIL"])')
check "Invite flips B's row to Invited before the server answers" 'echo "$ROW" | grep -q invited' 'echo "$SHEET" | head -c 700'
sleep 2; SHEET=$(B "$WA" canvas ui share state)
SAID=$(echo "$SHEET" | q 'd.get("said","")')
LISTED=$(echo "$SHEET" | q 'any(r["email"]==E["B_EMAIL"] and r["state"]=="invited" for r in d.get("pending",[]))')
check "the sheet confirms the invite and lists it as waiting" 'case "$SAID" in Invited*) [ "$LISTED" = True ];; *) false;; esac' 'echo "$SHEET" | head -c 700'
upto '[ -n "$(b_invite)" ]' 5
BI=$(b_invite)
if [ "$REMIND" = yes ]; then
  check "B's GET /v1/invites has it pending, invitee known" '[ "$(echo "$BI" | q "d.get(\"status\")==\"pending\" and (d.get(\"invitee\") or {}).get(\"email\")==E[\"B_EMAIL\"]")" = True ]' 'echo "$BI"'
else
  check "B's GET /v1/invites has it pending" '[ "$(echo "$BI" | q "d.get(\"status\")")" = pending ]' 'echo "$BI"'
fi
upto '[ "$(b_pill | cut -d"|" -f1)" = "$INV_CID" ]' 10
check "B's pill comes up for the invite (canvas pill)" '[ "$(b_pill | cut -d"|" -f1)" = "$INV_CID" ]' 'B "$WB" canvas pill'
B "$WB" ui history on >/dev/null 2>&1; sleep 1; shot "$WB" "final-invitee-pill-$VERSION.png"; B "$WB" ui history off >/dev/null 2>&1
check "B's Invitations list has it (canvas invites)" '[ "$(b_listed)" = True ]' 'B "$WB" canvas invites'
check "A's canvas pending lists B" '[ "$(B "$WA" canvas pending "$INV_CID" | q "any(i.get(\"email\")==E[\"B_EMAIL\"] for i in d.get(\"pending\",[]))")" = True ]' 'B "$WA" canvas pending "$INV_CID"'
B "$WB" canvas pill dismiss >/dev/null
check "Not now hides the pill and keeps the invite" '[ -z "$(b_pill | cut -d"|" -f1)" ] && [ "$(b_listed)" = True ]' 'B "$WB" canvas invites'
AGAIN=$(B "$WA" canvas remind "$INV_CID" "$B_EMAIL")
if [ "$REMIND" = yes ]; then WANT=False; else WANT=None; fi
check "re-inviting within 30 s reminds nobody" '[ "$(echo "$AGAIN" | q "str(d.get(\"made\")) + str(d.get(\"nudged\"))")" = "False$WANT" ]' 'echo "$AGAIN"'
sleep 4
check "…and B's pill stays down" '[ -z "$(b_pill | cut -d"|" -f1)" ]' 'B "$WB" canvas pill'
if [ "$REMIND" = yes ]; then
  WAIT=$(( INVITED_AT + 32 - $(date +%s) )); [ "$WAIT" -gt 0 ] && { echo "  (waiting ${WAIT}s for the 30 s reminder window)"; sleep "$WAIT"; }
  SHEET=$(B "$WA" canvas ui share resend "$B_EMAIL")
  SAID=$(echo "$SHEET" | q 'd.get("said","")')
  NUDGED=$(echo "$SHEET" | q 'any(r["email"]==E["B_EMAIL"] and r.get("nudgedAt") for r in d.get("pending",[]))')
  check "Resend after 30 s reminds B (the sheet says Reminded)" 'case "$SAID" in Reminded*) [ "$NUDGED" = True ];; *) false;; esac' 'echo "$SHEET" | head -c 700'
  upto '[ -n "$(b_pill | cut -d"|" -f2)" ]' 10
  check "B's pill comes back after the reminder" '[ "$(b_pill | cut -d"|" -f1)" = "$INV_CID" ] && [ -n "$(b_pill | cut -d"|" -f2)" ]' 'B "$WB" canvas pill'
  check "B's GET /v1/invites carries nudged_at" '[ "$(b_invite | q "bool(d.get(\"nudged_at\"))")" = True ]' 'b_invite'
  card "$WA" "final-share-sheet-$VERSION.png"
  B "$WB" ui settings on >/dev/null 2>&1; sleep 1; shot "$WB" "final-invitee-reminder-pill-$VERSION.png"; B "$WB" ui settings off >/dev/null 2>&1
  SHEET=$(B "$WA" canvas ui share withdraw "$B_EMAIL")
  SAID=$(echo "$SHEET" | q 'd.get("said","")')
  GONE=$(echo "$SHEET" | q 'not any(r["email"]==E["B_EMAIL"] for r in d.get("pending",[]))')
  check "× withdraws the invite (the sheet says Withdrew, the row goes)" 'case "$SAID" in Withdrew*) [ "$GONE" = True ];; *) false;; esac' 'echo "$SHEET" | head -c 700'
  upto '[ -z "$(b_invite)" ] && [ -z "$(b_pill | cut -d"|" -f1)" ] && [ "$(b_listed)" = False ]' 10
  check "the withdrawn invite is gone for B (GET /v1/invites, pill, Invitations)" '[ -z "$(b_invite)" ] && [ -z "$(b_pill | cut -d"|" -f1)" ] && [ "$(b_listed)" = False ]' 'b_invite; B "$WB" canvas invites'
  FRESH=$(B "$WA" canvas remind "$INV_CID" "$B_EMAIL")
  check "a withdrawn address can be invited afresh" '[ "$(echo "$FRESH" | q "d.get(\"made\")")" = True ]' 'echo "$FRESH"'
  upto '[ "$(b_pill | cut -d"|" -f1)" = "$INV_CID" ]' 10
  OPENED=$(B "$WB" canvas pill open)
  check "B joins from the pill's Open" '! echo "$OPENED" | grep -q "\"error\""' 'echo "$OPENED"'
else
  SHEET=$(B "$WA" canvas ui share state)
  ROW=$(echo "$SHEET" | q '",".join(str(r.get(k)) for r in d.get("pending",[]) if r["email"]==E["B_EMAIL"] for k in ("state","resend","withdraw"))')
  check "older cloud: the row says Invited, without Resend or ×" '[ "$ROW" = "invited,False,False" ]' 'echo "$SHEET" | head -c 700'
  check "older cloud: canvas pending says reminders aren't there" '[ "$(B "$WA" canvas pending "$INV_CID" | q "d.get(\"reminders\")")" = False ]' 'B "$WA" canvas pending "$INV_CID"'
  card "$WA" "final-share-sheet-$VERSION.png"
  B "$WB" canvas accept "$INV_CID" >/dev/null
fi
upto '[ "$(B "$WB" canvas list | q "any(r.get(\"id\")==E[\"INV_CID\"] and r.get(\"role\")==\"editor\" for r in d.get(\"canvases\",[]))")" = True ]' 10
check "B accepted and is an editor of the canvas" '[ "$(B "$WB" canvas list | q "any(r.get(\"id\")==E[\"INV_CID\"] and r.get(\"role\")==\"editor\" for r in d.get(\"canvases\",[]))")" = True ]' 'B "$WB" canvas list | head -c 600'
check "A's members list B and nothing waits any more" '[ "$(B "$WA" canvas members "$INV_CID" | q "any(m.get(\"email\")==E[\"B_EMAIL\"] for m in d.get(\"members\",[]))")" = True ] && [ -z "$(b_invite)" ]' 'B "$WA" canvas members "$INV_CID"; b_invite'

echo "== stale invites: a share-link join closes the invite, and Join on it still works"
# The live bug: B joined through the canvas's share link (which closes B's email
# invite) but B's Copper kept the pill and the Invitations row, and every Join or
# Decline on them got 404 and stayed. Now the join takes them off at once, and an
# answer on the stale invite id is no error: Join opens the canvas.
STALE_CID=$(B "$WA" canvas create "Stale $STAMP" | q 'd.get("id") or (d.get("canvas") or {}).get("id") or ""'); export STALE_CID
check "A created a canvas for the stale-invite case" '[ -n "$STALE_CID" ]' 'B "$WA" canvas list | head -c 400'
B "$WA" canvas remind "$STALE_CID" "$B_EMAIL" >/dev/null
s_iid() { curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/invites" | q 'next((i["id"] for i in L(d) if i.get("canvas_id")==E["STALE_CID"]), "")'; }
s_pill() { B "$WB" canvas pill | q '(d.get("pill") or {}).get("canvasId","")'; }
s_listed() { B "$WB" canvas invites | q 'any(i.get("canvasId")==E["STALE_CID"] for i in d.get("invites",[]))'; }
upto '[ -n "$(s_iid)" ] && [ "$(s_listed)" = True ]' 10
STALE_IID=$(s_iid)
check "B has the invite listed before joining by link" '[ -n "$STALE_IID" ] && [ "$(s_listed)" = True ]' 'B "$WB" canvas invites'
STALE_LINK=$(B "$WA" canvas link "$STALE_CID" | q 'd.get("link") or ""')
JOINED=$(B "$WB" canvas join "$STALE_LINK")
check "B joins the canvas through its share link" '! echo "$JOINED" | grep -q "\"error\"" && [ "$(B "$WB" canvas list | q "any(r.get(\"id\")==E[\"STALE_CID\"] for r in d.get(\"canvases\",[]))")" = True ]' 'echo "$JOINED"; B "$WB" canvas list | head -c 500'
check "the link join closed the invite on the server" '[ -z "$(s_iid)" ]' 's_iid'
check "B's pill and Invitations row for it are gone right after the join" '[ "$(s_pill)" != "$STALE_CID" ] && [ "$(s_listed)" = False ]' 'B "$WB" canvas pill; B "$WB" canvas invites'
# Another tab in front first, so "the canvas opens in front" is the Join's doing.
ELSE_TAB=$(B "$WB" open about:blank 2>/dev/null); B "$WB" select "$ELSE_TAB" >/dev/null 2>&1 || true
STALE=$(B "$WB" canvas stale accept "$STALE_IID" "$STALE_CID")
check "Join on the stale invite id: no error, and the canvas opens in front" '[ "$(echo "$STALE" | q "d.get(\"answer\")==\"opened\" and \"error\" not in d and d.get(\"front\")==E[\"STALE_CID\"] and d.get(\"listed\") is False")" = True ]' 'echo "$STALE"'
STALE=$(B "$WB" canvas stale decline "$STALE_IID" "$STALE_CID")
check "Decline on the stale invite id: no error, nothing left listed" '[ "$(echo "$STALE" | q "d.get(\"answer\")==\"closed\" and \"error\" not in d and d.get(\"listed\") is False and d.get(\"member\") is True")" = True ]' 'echo "$STALE"'
# An invite closed while B is not a member (declined on another Mac): Join says
# so quietly — no error, no canvas — and nothing is left listed.
GONE_CID=$(B "$WA" canvas create "Gone $STAMP" | q 'd.get("id") or (d.get("canvas") or {}).get("id") or ""'); export GONE_CID
B "$WA" canvas remind "$GONE_CID" "$B_EMAIL" >/dev/null
g_iid() { curl -ksS -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/invites" | q 'next((i["id"] for i in L(d) if i.get("canvas_id")==E["GONE_CID"]), "")'; }
upto '[ -n "$(g_iid)" ]' 10
GONE_IID=$(g_iid)
GONE_DECLINE=$(curl -ksS -o /dev/null -w '%{http_code}' -X POST -H "$H" -H "Authorization: Bearer $BTOKEN" "$HOST/v1/invites/$GONE_IID/decline")
STALE=$(B "$WB" canvas stale accept "$GONE_IID" "$GONE_CID")
check "Join on an invite declined elsewhere: no error, says it is no longer open, no canvas" '[ "$GONE_DECLINE" = 200 ] && [ "$(echo "$STALE" | q "d.get(\"answer\")==\"closed\" and \"error\" not in d and d.get(\"said\")==\"That invite is no longer open\" and d.get(\"member\") is False and d.get(\"listed\") is False and d.get(\"front\")!=E[\"GONE_CID\"]")" = True ]' 'echo "decline $GONE_DECLINE"; echo "$STALE"'

echo "== history: a push holding one address over 16 KiB goes through (no wedge)"
# 1,200 places the way an import leaves them, oldest first; #700 — in the second
# request of 500 — has a 20 KB sign-in address, over the cloud's 16 KiB per visit.
seed_history() { python3 - "$1" <<'PY'
import json, os, sys, time
w = sys.argv[1]
folder = os.path.expanduser(f"~/Library/Application Support/Copper ({w})")
REF = 978307200  # Foundation's reference date
now = time.time(); visits = []
for i in range(1200):
    url, title = f"https://site{i}.example/page", f"Page {i}"
    if i == 700:
        url, title = "https://sso.example/saml?SAMLRequest=" + "PHNhbWxwOkF1dGhuUmVxdWVzdC" * 800, "Sign in"
    visits.append({"url": url, "key": url.split("://", 1)[1].lower(), "title": title, "count": 1,
                   "last": now - 2 * 86400 + i * 60 - REF})
json.dump(visits, open(os.path.join(folder, "history.json"), "w"))
open(f"/tmp/copper-{w}.newest", "w").write(str(visits[-1]["last"] + REF))
PY
}
world "$WD" "$PD" seed_history; wait_bench "$WD"; sleep 2
D_EMAIL="d-$STAMP@example.com"
B "$WD" cloud link "$LINK_D" >/dev/null
check "D signs up" '[ "$(B "$WD" cloud signup "$D_EMAIL" "$PW" "Dana" | q "d.get(\"signedIn\")")" = True ]' 'B "$WD" cloud status'
B "$WD" cloud sync on history >/dev/null; B "$WD" cloud sync now >/dev/null
DTOKEN=$(curl -ksS -H "$H" -H 'Content-Type: application/json' -d "{\"email\":\"$D_EMAIL\",\"password\":\"$PW\",\"device\":{\"name\":\"e2e-history\"}}" "$HOST/v1/auth/login" | q 'd.get("token","")')
d_stored() { curl -ksS -H "$H" -H "Authorization: Bearer $DTOKEN" "$HOST/v1/sync/history?since=0&limit=2000" | q 'str(len(d.get("entries",[]))) + ("|sso" if any("sso.example" in (e.get("payload") or {}).get("url","") for e in d.get("entries",[])) else "") + ("|newest" if any((e.get("payload") or {}).get("url")=="https://site1199.example/page" for e in d.get("entries",[])) else "")'; }
upto '[ "$(d_stored)" = "1199|newest" ]' 40
STORED=$(d_stored)
check "every visit but the oversized one reaches the cloud" '[ "$STORED" = "1199|newest" ]' 'echo "stored: $STORED"; B "$WD" cloud log | tail -c 800'
export NEWEST=$(cat "/tmp/copper-$WD.newest" 2>/dev/null); rm -f "/tmp/copper-$WD.newest"
DSTATUS=$(B "$WD" cloud status)
check "the push isn't stuck: cursor at the newest visit, no retry waiting" '[ "$(echo "$DSTATUS" | q "(d[\"sync\"].get(\"historyPushedThrough\") or 0) >= float(E[\"NEWEST\"]) - 0.01 and d[\"sync\"].get(\"historyRetryAt\") is None")" = True ]' 'echo "$DSTATUS" | head -c 800'
check "the log says the oversized visit was left out" '{ B "$WD" cloud log || true; } | grep -q "left out a visit to sso.example"' 'B "$WD" cloud log | tail -c 800'

# The old section plus this section should finish with no failures.
echo "== done: $PASS passed, $FAIL failed"
for w in "$WA" "$WB" "$WC" "$WD"; do stop "$w"; done
[ "$FAIL" -eq 0 ]
