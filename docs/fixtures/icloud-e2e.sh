#!/bin/bash
# Two headless probe-world Coppers syncing through one folder (iCloud sync,
# Fork/FolderSync/): a phrase made on A, B joins with it, then bookmarks,
# pins, settings and history go both ways, edits made on both at once all
# land, a deletion travels, a wrong phrase and a damaged file are refused,
# a relaunch keeps sync on, and Stop Syncing with delete resets B.
#
#   docs/fixtures/icloud-e2e.sh [app-path]
#
# Never touches the browser somebody is using: each instance runs headless
# in its own SEARCH_PROBE world (default icloud-a / icloud-b, ports 4608 and
# 4609), and the folder is a fresh temporary one unless E2E_FOLDER names one.
# E2E_WORLD=NAME and E2E_PORT=N rename them. E2E_SHOTS=DIR keeps a picture of
# each world's iCloud sync section.
set -euo pipefail
APP=${1:-"$(cd "$(dirname "$0")/../.." && pwd)/build/Copper.app"}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=${E2E_WORLD:-icloud}; PORT=${E2E_PORT:-4608}
WA=$W-a; WB=$W-b; PA=$PORT; PB=$((PORT+1))
FOLDER=${E2E_FOLDER:-$(mktemp -d /tmp/icloud-e2e.XXXXXX)}
SHOTS=${E2E_SHOTS:-}
STAMP=$(date +%s)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 1200 || true)"; fi; }

# Only a pid this script started, and only while it is still this build.
stop() {
  local pid; pid=$(cat "/tmp/copper-$1.pid" 2>/dev/null) || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$APP/Contents/MacOS/Copper"*) kill "$pid" 2>/dev/null || true ;; esac
  rm -f "/tmp/copper-$1.pid"
}
launch() { # world port
  SEARCH_PROBE=$1 SEARCH_HEADLESS=1 SEARCH_MCP_PORT=$2 SEARCH_HEADLESS_SIZE=1440x1000 \
    "$APP/Contents/MacOS/Copper" >> "/tmp/copper-$1.log" 2>&1 &
  echo $! > "/tmp/copper-$1.pid"
}
world() { # world port: a fresh one
  stop "$1"; sleep 1
  rm -rf "$HOME/Library/Application Support/Copper ($1)"
  defaults delete "com.collinrijock.copper.test.$1" >/dev/null 2>&1 || true
  defaults write "com.collinrijock.copper.test.$1" bench -bool true
  defaults write "com.collinrijock.copper.test.$1" welcomed -bool true
  : > "/tmp/copper-$1.log"
  launch "$1" "$2"
}
B() { "$ROOT/bench" --world "$1" "${@:2}"; }
wait_bench() { for _ in $(seq 1 60); do B "$1" tabs >/dev/null 2>&1 && return 0; sleep 0.5; done; echo "bench never answered in $1"; return 1; }
json() { python3 -c "
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: d={'raw': raw.strip()}
try: print($1)
except Exception as e: print('')"; }
# Sync both, a few rounds: a file written by one is read by the other next.
both() { for _ in 1 2 3; do B "$WA" icloud now >/dev/null; B "$WB" icloud now >/dev/null; sleep "${E2E_SETTLE:-1}"; done; }
trap 'stop "$WA"; stop "$WB"' EXIT

echo "== launching $WA ($PA) and $WB ($PB), folder $FOLDER"
world "$WA" "$PA"; world "$WB" "$PB"
wait_bench "$WA"; wait_bench "$WB"; sleep 2

set +e
echo "== A turns sync on"
B "$WA" icloud folder "$FOLDER" >/dev/null; B "$WB" icloud folder "$FOLDER" >/dev/null
B "$WA" cloud bookmark "https://example.com/a-before-$STAMP" "A before" >/dev/null
ON=$(B "$WA" icloud on)
PHRASE=$(echo "$ON" | json 'd.get("phrase","")')
check "A made a 24-word phrase" '[ "$(echo $PHRASE | wc -w | tr -d " ")" = 24 ]' 'echo "$ON"'
B "$WA" icloud now >/dev/null
check "the folder holds only sealed files under random names" \
  '[ -z "$(find "$FOLDER" -type f ! -name "*.cps")" ] && ! grep -rq "a-before-$STAMP" "$FOLDER" && [ -n "$(find "$FOLDER" -name "*.cps")" ]' \
  'find "$FOLDER" | head; grep -rl "a-before" "$FOLDER"'
check "B sees the folder already holds sync data" 'B "$WB" icloud folder "$FOLDER" | json "d.get(\"holdsData\")" | grep -q True' 'B "$WB" icloud folder "$FOLDER"'
if [ -n "$SHOTS" ]; then
  mkdir -p "$SHOTS"
  B "$WA" icloud picture "$SHOTS/icloud-kit.png" kit >/dev/null
  B "$WB" icloud picture "$SHOTS/icloud-off-join.png" >/dev/null
fi

echo "== B joins"
WRONG=$(python3 -c "
import sys; w=sys.argv[1].split(); w[0],w[1]=w[1],w[0]; print(' '.join(w))" "$PHRASE")
[ "$WRONG" = "$PHRASE" ] && WRONG="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
check "a wrong phrase is refused" 'B "$WB" icloud join $WRONG 2>&1 | grep -qi "match\|not valid"' 'B "$WB" icloud join $WRONG 2>&1'
check "a phrase from nowhere is refused" 'B "$WB" icloud join abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art 2>&1 | grep -qi "match"' 'true'
B "$WB" cloud bookmark "https://example.com/b-before-$STAMP" "B before" >/dev/null
check "B joins with A's phrase" 'B "$WB" icloud join $PHRASE | json "d.get(\"on\")" | grep -q True' 'B "$WB" icloud status'
both
check "B is past joining" 'B "$WB" icloud status | json "d.get(\"joining\")" | grep -q False' 'B "$WB" icloud status'
check "A's bookmark reached B" 'B "$WB" cloud doc bookmarks >/dev/null; B "$WB" icloud doc bookmarks | grep -q "a-before-$STAMP"' 'B "$WB" icloud log | tail -8'
check "B's own bookmark survived the join and reached A" 'B "$WA" icloud doc bookmarks | grep -q "b-before-$STAMP"' 'B "$WA" icloud log | tail -8'
check "B lists A as another Mac" 'B "$WB" icloud status | json "[p[\"name\"] for p in d[\"peers\"]]" | grep -q "$WA"' 'B "$WB" icloud status'

echo "== both ways"
B "$WA" cloud pin "https://example.org/pinned-$STAMP" >/dev/null
B "$WA" icloud setting look dark >/dev/null
B "$WA" cloud open "https://example.com/?visited-$STAMP" >/dev/null; sleep 4 # an ordinary tab: bench tabs keep no history
both
check "A's pin reached B's spaces" 'B "$WB" icloud doc spaces | grep -q "pinned-$STAMP"' 'B "$WB" icloud log | tail -8'
check "the pin is open in B" 'B "$WB" tabs | grep -q "pinned-$STAMP"' 'B "$WB" tabs | head -20'
check "A's setting reached B" 'B "$WB" cloud doc settings | grep -q "\"look\": \"dark\""' 'B "$WB" cloud doc settings; B "$WB" icloud doc settings'
check "A's visit reached B's history" 'B "$WB" cloud doc history | grep -q "visited-$STAMP"' 'B "$WB" icloud doc history | head -30; B "$WB" cloud doc history | head -30'
check "B shows A's open tabs" 'B "$WB" icloud status | grep -q "visited-$STAMP"' 'B "$WB" icloud status'

echo "== edits on both at once"
B "$WA" cloud bookmark "https://example.com/a-both-$STAMP" "A both" >/dev/null
B "$WB" cloud bookmark "https://example.com/b-both-$STAMP" "B both" >/dev/null
sleep 1; both
check "A has both" 'B "$WA" icloud doc bookmarks | grep -q "a-both-$STAMP" && B "$WA" icloud doc bookmarks | grep -q "b-both-$STAMP"' 'B "$WA" icloud doc bookmarks'
check "B has both" 'B "$WB" icloud doc bookmarks | grep -q "a-both-$STAMP" && B "$WB" icloud doc bookmarks | grep -q "b-both-$STAMP"' 'B "$WB" icloud doc bookmarks'

echo "== a deletion travels"
B "$WB" icloud unbookmark "https://example.com/a-before-$STAMP" >/dev/null
sleep 1; both
check "B's removal reached the folder" '! B "$WA" icloud doc bookmarks | grep -q "a-before-$STAMP"' 'B "$WA" icloud doc bookmarks'
check "and A's own bookmarks" '! B "$WA" cloud doc bookmarks | grep -q "a-before-$STAMP"' 'B "$WA" cloud doc bookmarks | head -30'

echo "== damaged and foreign files"
SCOPE=$(dirname "$(find "$FOLDER" -name "*.cps" | head -1)")
head -c 600 /dev/urandom > "$SCOPE/garbage$STAMP.cps"
printf 'not ours' > "$SCOPE/notes.txt"
both
check "a damaged file is set aside, sync goes on" 'B "$WA" icloud status | json "(d[\"damaged\"], d[\"status\"])" | grep -q "(1, .updated.)"' 'B "$WA" icloud status'
rm -f "$SCOPE/garbage$STAMP.cps" "$SCOPE/notes.txt"

echo "== relaunch"
stop "$WB"; sleep 2; launch "$WB" "$PB"; wait_bench "$WB"; sleep 4
B "$WA" cloud bookmark "https://example.com/after-relaunch-$STAMP" "after" >/dev/null
both
check "B is still on after a relaunch" 'B "$WB" icloud status | json "d.get(\"on\")" | grep -q True' 'B "$WB" icloud status'
check "and still syncing" 'B "$WB" cloud doc bookmarks | grep -q "after-relaunch-$STAMP"' 'B "$WB" icloud log | tail -8'

if [ -n "$SHOTS" ]; then
  B "$WA" icloud picture "$SHOTS/icloud-on.png" >/dev/null
  B "$WA" icloud picture "$SHOTS/icloud-on-dark.png" dark >/dev/null
  B "$WA" icloud kit "$SHOTS/recovery-kit.pdf" >/dev/null
  echo "$PHRASE" > "$SHOTS/phrase.txt" # a throwaway chain, deleted below: for checking the kit's QR code
fi

echo "== stop syncing, deleting the data"
B "$WA" icloud off delete >/dev/null
check "the phrase's folder is gone" '[ -z "$(find "$FOLDER" -name "*.cps")" ]' 'find "$FOLDER" | head'
both
check "B sees the reset and stops" 'B "$WB" icloud status | json "(d[\"on\"], d[\"status\"])" | grep -q "(False, .reset.)"' 'B "$WB" icloud status'
check "B kept its data" 'B "$WB" cloud doc bookmarks | grep -q "after-relaunch-$STAMP"' 'B "$WB" cloud doc bookmarks | head'
[ -n "$SHOTS" ] && B "$WB" icloud picture "$SHOTS/icloud-reset.png" >/dev/null

echo "== $PASS passed, $FAIL failed"
[ -z "${E2E_FOLDER:-}" ] && rm -rf "$FOLDER"
[ "$FAIL" = 0 ]
