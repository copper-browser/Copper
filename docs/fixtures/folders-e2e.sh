#!/bin/bash
# Live folders and shared folders (Fork/LiveFolders.swift, Fork/SharedFolders.swift)
# in two headless probe worlds.
#
# Shared folders: A shares a Saved folder; its directory holds only sealed
# files. B, whose "iCloud Drive" is another folder where the shared directory
# shows up (a symlink, as iCloud puts a folder someone shares with you),
# joins with the invite link: a wrong invite and a missing directory are
# refused, then the links arrive with their subfolder. Adds, closes, a move
# into a subfolder and a rename go both ways; edits on both at once both land;
# a flattened folder is held, not deleted for everyone; a damaged file is set
# aside; B relaunches still bound; Stop Syncing keeps B's tabs and cuts it off.
#
# Live folders: against a stand-in for api.github.com on 127.0.0.1 — no
# token, a wrong token, the right one (first fill quiet), a pull request that
# changed and a new one light up, opening one makes its tab and clears its
# dot, opening it again reuses the tab, and a rate limit is said.
#
#   docs/fixtures/folders-e2e.sh [app-path]
#
# Never touches the browser somebody is using: worlds folders-a / folders-b
# (ports 4615 and 14615), temporary folders. E2E_WORLD / E2E_PORT rename
# them; E2E_SHOTS=DIR keeps pictures.
set -euo pipefail
APP=${1:-"$(cd "$(dirname "$0")/../.." && pwd)/build/Copper.app"}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=${E2E_WORLD:-folders}; PORT=${E2E_PORT:-4615}
WA=$W-a; WB=$W-b; PA=$PORT; PB=$((PORT+10000)); GH=$((PORT+20000))
TMP=$(mktemp -d /tmp/folders-e2e.XXXXXX)
DRIVE_A="$TMP/drive-a"; DRIVE_B="$TMP/drive-b"; mkdir -p "$DRIVE_A" "$DRIVE_B"
SHOTS=${E2E_SHOTS:-}
STAMP=$(date +%s)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 — $( { eval "$3"; } 2>&1 | head -c 1500 || true)"; fi; }

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
  defaults write "com.collinrijock.copper.test.$1" sidebar -bool true
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
both() { for _ in 1 2 3; do B "$WA" folders shared now >/dev/null; B "$WB" folders shared now >/dev/null; sleep "${E2E_SETTLE:-1}"; done; }
links() { B "$1" folders shared links "$2"; }
GHPID=""
trap 'stop "$WA"; stop "$WB"; [ -n "$GHPID" ] && kill "$GHPID" 2>/dev/null; rm -rf "$TMP"' EXIT

# A stand-in for api.github.com: /user and /search/issues, behind one token.
# $TMP/gh.json is what it answers; editing it is GitHub changing.
cat > "$TMP/gh.py" <<'PY'
import http.server, json, sys, urllib.parse
port, token, state = int(sys.argv[1]), sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, headers={}):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in headers.items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        s = json.load(open(state))
        if s.get("limited"): return self.send(403, {"message": "API rate limit exceeded"}, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "4102444800"})
        if self.headers.get("Authorization") != "Bearer " + token: return self.send(401, {"message": "Bad credentials"})
        u = urllib.parse.urlparse(self.path)
        if u.path == "/user": return self.send(200, {"login": "octo-e2e"})
        if u.path == "/search/issues":
            q = urllib.parse.parse_qs(u.query).get("q", [""])[0]
            items = s["reviews"] if "review-requested:@me" in q else s["mine"] if "author:@me" in q else []
            return self.send(200, {"total_count": len(items), "incomplete_results": False, "items": items})
        self.send(404, {"message": "Not Found"})
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
pr() { # number title updated [draft]
  echo "{\"html_url\":\"https://example.com/acme/site/pull/$1\",\"title\":\"$2\",\"number\":$1,\"updated_at\":\"$3\",\"draft\":${4:-false},\"user\":{\"login\":\"sam\"},\"repository_url\":\"https://api.github.com/repos/acme/site\"}"
}
gh_state() { echo "{\"limited\":${3:-false},\"reviews\":[$1],\"mine\":[$2]}" > "$TMP/gh.json"; }
gh_state "$(pr 11 'Fix the header' 2026-11-20T10:00:00Z),$(pr 12 'Dark mode' 2026-11-21T10:00:00Z)" "$(pr 21 'Live folders' 2026-11-22T10:00:00Z true)"
TOKEN="e2e-token-$STAMP"; echo "$TOKEN" > "$TMP/token"; echo "wrong-$STAMP" > "$TMP/wrong"
python3 "$TMP/gh.py" "$GH" "$TOKEN" "$TMP/gh.json" & GHPID=$!

echo "== launching $WA ($PA) and $WB ($PB), GitHub stand-in on $GH"
world "$WA" "$PA"; world "$WB" "$PB"
wait_bench "$WA"; wait_bench "$WB"; sleep 2

set +e
B "$WA" folders shared root "$DRIVE_A" >/dev/null
B "$WB" folders shared root "$DRIVE_B" >/dev/null

echo "== A shares a folder"
B "$WA" folders shared add Trip "https://example.com/hotel-$STAMP" >/dev/null
B "$WA" folders shared add Trip "https://example.org/flights-$STAMP" >/dev/null
B "$WA" folders shared add Trip "https://example.net/museum-$STAMP" Deep >/dev/null
SHARE=$(B "$WA" folders shared share Trip)
LINK=$(echo "$SHARE" | json 'd.get("link","")')
WORDS=$(echo "$SHARE" | json 'd.get("words","")')
DIR="$DRIVE_A/Copper Shared/Trip"
check "A's invite is a copper://folder/join link and 24 words" '[[ "$LINK" == copper://folder/join?k=* ]] && [ "$(echo $WORDS | wc -w | tr -d " ")" = 24 ]' 'echo "$SHARE"'
check "the directory is iCloud Drive › Copper Shared › Trip" '[ -d "$DIR" ]' 'find "$DRIVE_A" | head'
check "it holds only sealed files, no address readable" \
  '[ -n "$(find "$DIR" -name "*.cps")" ] && [ -z "$(find "$DIR" -type f ! -name "*.cps")" ] && ! grep -rqE "hotel-$STAMP|example" "$DIR"' \
  'find "$DIR" -type f | head; grep -rl example "$DIR"'
check "A's folder says up to date" 'B "$WA" folders shared | grep -q "Up to date"' 'B "$WA" folders shared'

echo "== B joins"
check "a wrong invite is refused" '{ B "$WB" folders shared join "hello there" 2>&1 || true; } | grep -qi "isn.t a Copper shared folder invite"' 'B "$WB" folders shared join "hello there" 2>&1'
BADWORDS=$(python3 -c "import sys; w=sys.argv[1].split(); w[0],w[1]=w[1],w[0]; print(' '.join(w))" "$WORDS")
check "a mistyped phrase is refused" '{ B "$WB" folders shared join $BADWORDS 2>&1 || true; } | grep -qiE "not valid|couldn.t find"' 'B "$WB" folders shared join $BADWORDS 2>&1'
check "before the directory reaches B, joining says to accept the iCloud invitation" \
  '{ B "$WB" folders shared join "$LINK" 2>&1 || true; } | grep -qi "Accept the iCloud invitation"' 'B "$WB" folders shared join "$LINK" 2>&1'
ln -s "$DIR" "$DRIVE_B/Trip" # iCloud Drive: a folder shared with you appears at the top
JOIN=$(B "$WB" folders shared join "$LINK")
check "B joins with the link" 'echo "$JOIN" | json "d.get(\"joined\")" | grep -q Trip' 'echo "$JOIN"'
both
check "A's three links reached B, the museum in Deep" \
  'L=$(links "$WB" Trip); echo "$L" | grep -q "hotel-$STAMP" && echo "$L" | grep -q "flights-$STAMP" && echo "$L" | json "[l[0] for l in d[\"links\"] if \"museum-$STAMP\" in l[1]]" | grep -q Deep' \
  'links "$WB" Trip; B "$WB" folders shared log | tail -10'
check "B's tabs are Saved rows in its sidebar" 'B "$WB" groups plan | grep -q "museum\|example.net"' 'B "$WB" groups plan'

echo "== both ways"
B "$WB" folders shared add Trip "https://example.com/b-added-$STAMP" >/dev/null
B "$WA" folders shared close Trip "https://example.org/flights-$STAMP" >/dev/null
sleep 1; both
check "B's new link reached A" 'links "$WA" Trip | grep -q "b-added-$STAMP"' 'links "$WA" Trip; B "$WA" folders shared log | tail -8'
check "A's closed link left B" '! links "$WB" Trip | grep -q "flights-$STAMP"' 'links "$WB" Trip; B "$WB" folders shared log | tail -8'
B "$WB" folders shared move Trip "https://example.com/hotel-$STAMP" Deep >/dev/null
B "$WA" folders shared rename Trip Holiday >/dev/null
sleep 1; both
check "B's move into Deep reached A" 'links "$WA" Holiday | json "[l[0] for l in d[\"links\"] if \"hotel-$STAMP\" in l[1]]" | grep -q Deep' 'links "$WA" Holiday'
check "A's rename reached B" 'links "$WB" Holiday | grep -q "hotel-$STAMP"' 'B "$WB" groups; B "$WB" folders shared log | tail -8'

echo "== edits on both at once"
B "$WA" folders shared add Holiday "https://example.com/a-both-$STAMP" >/dev/null
B "$WB" folders shared add Holiday "https://example.com/b-both-$STAMP" >/dev/null
sleep 1; both
check "A has both" 'L=$(links "$WA" Holiday); echo "$L" | grep -q "a-both-$STAMP" && echo "$L" | grep -q "b-both-$STAMP"' 'links "$WA" Holiday'
check "B has both" 'L=$(links "$WB" Holiday); echo "$L" | grep -q "a-both-$STAMP" && echo "$L" | grep -q "b-both-$STAMP"' 'links "$WB" Holiday'
check "and the same five links" '[ "$(links "$WA" Holiday | json "sorted(l[1] for l in d[\"links\"])")" = "$(links "$WB" Holiday | json "sorted(l[1] for l in d[\"links\"])")" ]' 'links "$WA" Holiday; links "$WB" Holiday'

echo "== a flattened folder is held"
B "$WA" folders shared close Holiday $(links "$WA" Holiday | json "' '.join(l[1] for l in d['links'][1:])") >/dev/null
sleep 1; both
check "A holds the four links it lost at once" 'B "$WA" folders shared | grep -q "held"' 'B "$WA" folders shared'
check "B still has all five" '[ "$(links "$WB" Holiday | json "len(d[\"links\"])")" = 5 ]' 'links "$WB" Holiday'
B "$WA" folders shared back Holiday >/dev/null; sleep 1; both
check "Put Back brings them back to A" '[ "$(links "$WA" Holiday | json "len(d[\"links\"])")" = 5 ]' 'links "$WA" Holiday; B "$WA" folders shared'

echo "== a damaged file"
SCOPE=$(dirname "$(find "$DIR" -name "*.cps" | head -1)")
head -c 600 /dev/urandom > "$SCOPE/garbage$STAMP.cps"
both
check "is set aside, sync goes on" 'B "$WB" folders shared | json "(d[\"folders\"][0][\"damaged\"], d[\"folders\"][0][\"health\"])" | grep -q "(1, .Up to date.)"' 'B "$WB" folders shared'
rm -f "$SCOPE/garbage$STAMP.cps"

echo "== relaunch"
stop "$WB"; sleep 2; launch "$WB" "$PB"; wait_bench "$WB"; sleep 4
B "$WA" folders shared add Holiday "https://example.com/after-relaunch-$STAMP" >/dev/null
both
check "B is still bound after a relaunch" 'B "$WB" folders shared | json "len(d[\"folders\"])" | grep -q 1' 'B "$WB" folders shared'
check "and still syncing" 'links "$WB" Holiday | grep -q "after-relaunch-$STAMP"' 'links "$WB" Holiday; B "$WB" folders shared log | tail -8'

echo "== live folders"
B "$WA" folders live api "http://127.0.0.1:$GH" >/dev/null
B "$WA" folders live add >/dev/null; sleep 1
check "with no token the folder says to add one" 'B "$WA" folders live | grep -q "Add a GitHub token"' 'B "$WA" folders live'
check "a wrong token is refused" '{ B "$WA" folders live token-file "$TMP/wrong" 2>&1 || true; } | grep -q "didn.t take the token"' 'B "$WA" folders live token-file "$TMP/wrong" 2>&1'
LIVE=$(B "$WA" folders live token-file "$TMP/token")
check "the right token fills it: two review requests, then yours" \
  '[ "$(echo "$LIVE" | json "[i[\"number\"] for i in d[\"folders\"][0][\"items\"]]")" = "[12, 11, 21]" ] && echo "$LIVE" | json "d[\"login\"]" | grep -q octo-e2e' 'echo "$LIVE"'
check "the first fill lights nothing" '[ "$(echo "$LIVE" | json "d[\"folders\"][0][\"unread\"]")" = 0 ]' 'echo "$LIVE"'
check "the token is in the world's 0600 secrets file, not the folder file" \
  'F=$(ls "$HOME/Library/Application Support/Copper ($WA)/secrets/"*GitHub*); [ "$(stat -f %Lp "$F")" = 600 ] && ! grep -q "$TOKEN" "$HOME/Library/Application Support/Copper ($WA)/live-folders.json"' \
  'ls -l "$HOME/Library/Application Support/Copper ($WA)/secrets/"'
gh_state "$(pr 11 'Fix the header' 2026-11-20T10:00:00Z),$(pr 12 'Dark mode' 2026-11-25T18:00:00Z),$(pr 13 'New one' 2026-11-25T19:00:00Z)" "$(pr 21 'Live folders' 2026-11-22T10:00:00Z true)"
LIVE=$(B "$WA" folders live refresh)
check "a changed and a new pull request light up" \
  '[ "$(echo "$LIVE" | json "sorted(i[\"number\"] for i in d[\"folders\"][0][\"items\"] if i[\"unread\"])")" = "[12, 13]" ]' 'echo "$LIVE"'
[ -n "$SHOTS" ] && { mkdir -p "$SHOTS"; B "$WA" folders live picture "$SHOTS/folders-sidebar.png" >/dev/null; B "$WA" folders shared sheet Holiday "$SHOTS/shared-sheet.png" >/dev/null; }
OPEN=$(B "$WA" folders live open 0)
check "opening one makes its tab, in front" 'echo "$OPEN" | json "d[\"active\"]" | grep -q "pull/13"' 'echo "$OPEN"'
check "and clears its dot" '[ "$(echo "$OPEN" | json "[i[\"unread\"] for i in d[\"folders\"][0][\"items\"] if i[\"number\"]==13][0]")" = False ]' 'echo "$OPEN"'
TABS=$(echo "$OPEN" | json 'd["tabs"]')
AGAIN=$(B "$WA" folders live open 0)
check "opening it again goes to that tab" '[ "$(echo "$AGAIN" | json "d[\"tabs\"]")" = "$TABS" ]' 'echo "$OPEN"; echo "$AGAIN"'
gh_state "" "" true
check "GitHub's rate limit is said, the list kept" \
  'R=$(B "$WA" folders live refresh); echo "$R" | grep -q "request limit" && [ "$(echo "$R" | json "len(d[\"folders\"][0][\"items\"])")" = 4 ]' 'B "$WA" folders live'

echo "== stop syncing"
B "$WB" folders shared stop Holiday >/dev/null
B "$WA" folders shared add Holiday "https://example.com/after-stop-$STAMP" >/dev/null
both
check "B keeps its folder and tabs" '[ "$(links "$WB" Holiday | json "len(d[\"links\"])")" -ge 5 ]' 'links "$WB" Holiday'
check "and gets nothing new" '! links "$WB" Holiday | grep -q "after-stop-$STAMP"' 'links "$WB" Holiday'
mv "$DIR" "$TMP/moved-away"
both
check "A says the directory is missing" 'B "$WA" folders shared | grep -q "missing"' 'B "$WA" folders shared'
[ -n "$SHOTS" ] && B "$WB" folders shared picture "$SHOTS/folders-sidebar-b.png" >/dev/null

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
