#!/bin/bash
# Move in from Chrome (and Arc), end to end, in fresh headless worlds:
#
# Chrome — locked, then let in:
#   - macOS keeps Chrome's folder private (simulated: `flow access … locked`,
#     no folder touched): the card has one sentence, "Allow in System
#     Settings…" and "Use an export instead…"; Allow names Files & Folders;
#   - the export pane takes Chrome's bookmarks HTML (twice: nothing doubles)
#     and a passwords CSV (into the test run's stand-in), and says plainly
#     what a file it can't use is;
#   - access is granted (the lock cleared) and Copper comes back to the front
#     (`flow activate`): the card unlocks without reopening, one re-check;
#   - Return moves; the summary has a line per category and stays up; Done
#     lands on the first imported space; reopening shows the picker;
#   - moving in again adds nothing — no tab, space, bookmark or place;
#   - (generated fixture) a third move with one more tab in Chrome fills the
#     space, and Undo takes back only that tab.
# Arc — twice, from a copy (`--arc DIR`, the folder holding
#   StorableSidebar.json and User Data; skipped without it):
#   - the copy's sidebar is read, not the live one;
#   - the second move makes no space and adds no tab; no "(Arc)" names;
#   - every imported space survives the Today sweep when it is shown.
#
#   docs/fixtures/flow-move-e2e.sh [--chrome DIR] [--arc DIR] [--shots DIR] [build/Copper.app]
#     --chrome DIR  a read-only copy of a Chrome user-data folder (default: a
#                   generated one-window fixture with bookmarks and history)
#     --arc DIR     a read-only copy of Arc's folder
#     --shots DIR   keep light and dark pictures of every sheet state there
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHROME=""
ARC=""
SHOTS=""
APP="$ROOT/build/Copper.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --chrome) CHROME="$2"; shift 2 ;;
    --arc) ARC="$2"; shift 2 ;;
    --shots) SHOTS="$2"; shift 2 ;;
    *) APP="$1"; shift ;;
  esac
done
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-move.XXXXXX")
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
  for _ in $(seq 1 100); do
    state=$(B flow state)
    if printf '%s\n' "$state" | jq -e "$1" >/dev/null; then printf '%s\n' "$state"; return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $1: $state"
}
# shot NAME: the sheet as drawn, light and dark
shot() {
  [ -n "$SHOTS" ] || return 0
  mkdir -p "$SHOTS"
  for look in light dark; do
    B ui look "$look" >/dev/null
    sleep 0.4
    B flow shot --path "$SHOTS/$1-$look.png" >/dev/null || fail "shot $1 $look"
  done
  B ui look light >/dev/null
}
launch() {
  WORLD="flowmove$1$(date +%s)$$"
  WORLDS+=("$WORLD")
  local port=$((45000 + ($$ + ${#WORLDS[@]}) % 9000))
  defaults write "com.collinrijock.copper.test.$WORLD" bench -bool true
  defaults write "com.collinrijock.copper.test.$WORLD" welcomed -bool true
  open -n -g --stderr "$TEMP/$1.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 \
    --env SEARCH_MCP_PORT="$port" --env SEARCH_HEADLESS_SIZE=1440x960 "$APP"
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
session() { # session FILE URL… — one window, a tab per URL (SNSS v1)
  local file="$1"; shift
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
  ' "$@" > "$file"
}

# ---------------------------------------------------------------- Chrome
GENERATED=0
if [ -z "$CHROME" ]; then
  GENERATED=1
  CHROME="$TEMP/Chrome"
  mkdir -p "$CHROME/Default/Sessions"
  printf '{"profile":{"name":"Default"}}\n' > "$CHROME/Default/Preferences"
  session "$CHROME/Default/Sessions/Current Session" "https://alpha.invalid/one"
  python3 - "$CHROME/Default" <<'PY'
import json, os, sqlite3, sys, time
profile = sys.argv[1]
json.dump({"roots": {"bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
    {"type": "url", "name": "Alpha", "url": "https://alpha.invalid/"}]},
    "other": {"type": "folder", "name": "Other bookmarks", "children": []},
    "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}}, "version": 1},
    open(os.path.join(profile, "Bookmarks"), "w"))
db = sqlite3.connect(os.path.join(profile, "History"))
db.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER)")
db.execute("INSERT INTO urls VALUES (1, 'https://alpha.invalid/one', 'One', 2, 0, ?, 0)", (int((time.time() + 11644473600) * 1e6),))
db.commit(); db.close()
PY
fi
# Chrome's own export files, as its menus write them.
cat > "$TEMP/bookmarks.html" <<'HTML'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://exported.invalid/a" ADD_DATE="1700000000">Exported A</A>
        <DT><A HREF="https://exported.invalid/b" ADD_DATE="1700000000">Exported B</A>
    </DL><p>
    <DT><A HREF="https://exported.invalid/other" ADD_DATE="1700000000">Exported other</A>
</DL><p>
HTML
printf 'name,url,username,password,note\nExported,https://exported.invalid/login,me,exported-secret,\n' > "$TEMP/passwords.csv"
printf 'title,url\nNot passwords,https://exported.invalid/\n' > "$TEMP/notes.csv"

launch chrome
B flow limit --only Chrome >/dev/null
B flow access --source Chrome locked >/dev/null
B flow root --source Chrome --path "$CHROME" >/dev/null
SPACES0=$(B flow spaces | jq '.spaces | length')
B flow events --clear >/dev/null

B flow open >/dev/null
STATE=$(until_state '.showing and .sourcesKnown')
check "locked card" '.sources == [{"name":"Chrome","locked":true,"empty":false}] and .selected == "" and .phase == "idle"' "$STATE"
check "Allow names Files & Folders" '.page | endswith("Privacy_FilesAndFolders")' "$(B flow allow)"
shot locked
ok "locked: one sentence, Allow in System Settings… (Files & Folders), Use an export instead…"

B flow export --source Chrome >/dev/null
until_state '.exporting == "Chrome"' >/dev/null
shot export
R=$(B flow file --path "$TEMP/bookmarks.html")
check "bookmarks HTML" '.ok and .text == "3 bookmarks from Chrome'"'"'s file"' "$R"
N1=$(printf '%s\n' "$R" | jq '.bookmarks')
R=$(B flow file --path "$TEMP/bookmarks.html")
check "bookmarks HTML again" '(.ok | not) and (.text | startswith("Nothing new"))' "$R"
[ "$(printf '%s\n' "$R" | jq '.bookmarks')" = "$N1" ] || fail "the same file twice doubled the bookmarks"
R=$(B flow file --path "$TEMP/passwords.csv")
check "passwords CSV" '.ok and .text == "1 password imported"' "$R"
check "CSV went to the stand-in" '[.passwords[] | select(.host == "exported.invalid" and .user == "me")] | length == 1' "$(B flow secrets)"
R=$(B flow file --path "$TEMP/notes.csv")
check "a CSV that isn't passwords" '(.ok | not) and (.text | startswith("That isn'"'"'t a bookmarks or passwords file"))' "$R"
shot export-result
# A big export: 20,000 loose bookmarks. It is read and merged off the main
# thread, so the window answers throughout (every bench call is answered on
# the main thread; the slowest one while the file is taken is the stall).
python3 - "$TEMP/big.html" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write('<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n')
    for i in range(20000):
        f.write(f'<DT><A HREF="https://big{i}.invalid/">Big {i}</A>\n')
    f.write('</DL><p>\n')
PY
STALL=$(python3 - "$HOME/Library/Application Support/Copper ($WORLD)/bench.sock" "$TEMP/big.html" <<'PY'
import json, socket, sys, time
path, big = sys.argv[1], sys.argv[2]
def ask(req):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(path)
        s.sendall((json.dumps(req) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
    return json.loads(data.split(b"\n", 1)[0] or b"{}")
ask({"do": "flow", "op": "file", "path": big})
worst, start, st = 0.0, time.time(), {}
while time.time() - start < 60:
    t = time.time()
    st = ask({"do": "flow", "op": "file-status"})
    worst = max(worst, time.time() - t)
    if not st.get("running"): break
    time.sleep(0.02)
print(json.dumps({"worst": round(worst, 3), "seconds": round(time.time() - start, 2),
                  "text": st.get("text"), "bookmarks": st.get("bookmarks")}))
PY
)
check "20,000 bookmarks arrive" '.text == "20,000 bookmarks from Chrome'"'"'s file"' "$STALL"
check "the window answered throughout" '.worst < 0.25' "$STALL"
B flow back >/dev/null
ok "export: bookmarks HTML ×2 stable at $N1 bookmarks; passwords CSV into the stand-in; a wrong file is said plainly; 20,000 loose bookmarks in $(printf '%s' "$STALL" | jq -r .seconds) s, slowest answer $(printf '%s' "$STALL" | jq -r .worst) s"

# Access granted in System Settings; Copper comes back to the front.
B flow events --clear >/dev/null
B flow access --source Chrome clear >/dev/null
B flow activate >/dev/null
STATE=$(until_state '.phase == "preview"')
check "unlocked without reopening" '.sources == [{"name":"Chrome","locked":false,"empty":false}] and .selected == "Chrome" and .showing' "$STATE"
EVENTS=$(B flow events)
check "one re-check, one scan" '.counts.refresh == 1 and .counts.scan == 1 and (.counts.present // 0) == 0' "$EVENTS"
B flow activate >/dev/null
sleep 0.5
check "nothing locked: activation re-reads nothing" '.counts.refresh == 1' "$(B flow events)"
shot picker
ok "granted: the card unlocked on activation, one re-check, one scan, no reopen"

B flow choose --only tabs,bookmarks,history >/dev/null
B flow key return >/dev/null
STATE=$(until_state '.phase == "done"')
shot done
FIRST=$(B flow status)
printf '%s\n' "$FIRST" | jq -r '.summary[]' | sed 's/^/     /'
if [ "$GENERATED" = 1 ]; then
  check "first move" '.tabs == 1 and .spacesMade == 1 and .bookmarks == 1 and .places == 1' "$FIRST"
  check "summary all ✓" '[.summary[] | startswith("✓")] | all and length == 3' "$FIRST"
  check "guide offered" '.guideOffered' "$FIRST"
else
  check "a copy with nothing open makes no space" '.tabs == 0 and .spacesMade == 0' "$FIRST"
  check "summary says why" '.summary[0] | test("^— Tabs: Chrome.s (last|open) window")' "$FIRST"
fi
LANDING=$(printf '%s\n' "$FIRST" | jq -r '.landing')
sleep 1
check "the summary stays up" '.showing and .phase == "done"' "$(B flow state)"
B flow key return >/dev/null
until_state '.showing | not' >/dev/null
if [ -n "$LANDING" ]; then
  [ "$(B flow spaces | jq -r '.current')" = "$LANDING" ] || fail "Done did not land on the first imported space"
fi
ok "Return moved; the summary stayed until Done; Done landed on ${LANDING:-the space it was on}"

B flow open --via command >/dev/null
STATE=$(until_state '.showing and .phase != "done" and .sourcesKnown')
check "reopen is the picker, every switch on" '(.phase == "idle" or .phase == "scanning" or .phase == "preview") and (.choice | all)' "$STATE"
STATE=$(until_state '.phase == "preview"')
shot moved-before
B flow key escape >/dev/null
until_state '.showing | not' >/dev/null
ok "reopen after a move starts fresh"

SPACES1=$(B flow spaces | jq '.spaces | length')
SECOND=$(B flow move --source Chrome --only tabs,bookmarks,history 2>/dev/null)
printf '%s\n' "$SECOND" | jq -r '.summary[]' | sed 's/^/     /'
check "second move adds nothing" '.tabs == 0 and .spacesMade == 0 and .spacesFilled == 0 and .bookmarksNew == 0 and .placesNew == 0' "$SECOND"
[ "$(B flow spaces | jq '.spaces | length')" = "$SPACES1" ] || fail "second move changed the spaces"
B flow spaces | jq -e '[.spaces[] | select(.tabs == 0 and (.name | startswith("Chrome")))] | length == 0' >/dev/null || fail "an empty Chrome space exists"
ok "second move: nothing new — $SPACES1 spaces (was $SPACES0 before the first), no empty Chrome space"

if [ "$GENERATED" = 1 ]; then
  session "$CHROME/Default/Sessions/Current Session" "https://alpha.invalid/one" "https://alpha.invalid/two"
  THIRD=$(B flow move --source Chrome --only tabs 2>/dev/null)
  check "third move fills" '.tabs == 1 and .tabsSkipped == 1 and .spacesFilled == 1 and .spacesMade == 0' "$THIRD"
  CHROME_SPACE=$(B flow registry --source Chrome | jq -r '.registry.chrome')
  [ "$(B flow spaces | jq --arg id "$CHROME_SPACE" '[.spaces[] | select(.id == $id)][0].tabs')" = 2 ] || fail "the filled space does not have both tabs"
  B flow undo >/dev/null
  [ "$(B flow spaces | jq --arg id "$CHROME_SPACE" '[.spaces[] | select(.id == $id)][0].tabs')" = 1 ] || fail "Undo did not take back just the new tab"
  [ "$(B flow registry --source Chrome | jq -r '.registry.chrome')" = "$CHROME_SPACE" ] || fail "Undo forgot a space it didn't make"
  ok "third move filled the space with the one new tab; Undo took back only that tab"
fi
quit

# ---------------------------------------------------------------- Arc
if [ -n "$ARC" ]; then
  [ -f "$ARC/StorableSidebar.json" ] || fail "--arc needs a folder with StorableSidebar.json"
  launch arc
  B flow limit --only Arc >/dev/null
  B flow root --source Arc --path "$ARC/User Data" >/dev/null
  SPACES0=$(B flow spaces | jq '.spaces | length')
  READ=$(B flow scan --source Arc | jq '.spaces')
  FIRST=$(B flow move --source Arc --only tabs 2>/dev/null)
  MADE=$(printf '%s\n' "$FIRST" | jq '.spacesMade')
  TABS=$(printf '%s\n' "$FIRST" | jq '.tabs')
  [ "$MADE" -gt 0 ] || fail "the Arc copy made no space: $FIRST"
  printf '%s\n' "$FIRST" | jq -r '.summary[]' | sed 's/^/     /'
  # A space Arc has that made none here (nothing of its own to open) is said.
  if [ "$READ" -gt "$MADE" ]; then
    LEFT=$((READ - MADE))
    printf '%s\n' "$FIRST" | jq -e --arg n "$LEFT" '[.summary[] | select(test("Tabs: .* " + $n + " empty spaces? left out"))] | length == 1' >/dev/null \
      || fail "Arc has $READ spaces, $MADE made, but the summary doesn't say $LEFT were left out: $FIRST"
  fi
  SPACES1=$(B flow spaces | jq '.spaces | length')
  [ "$SPACES1" = $((SPACES0 + MADE)) ] || fail "space count is not before + made"
  # Show every space, then sweep Today as the clock would: nothing goes.
  BEFORE=$(B flow spaces | jq '[.spaces[].tabs] | add')
  for i in $(seq 0 $((SPACES1 - 1))); do
    B windows space 0 "$i" >/dev/null
    sleep 0.2
    # `sections archive` prints "archived N tab(s)": the sweep the clock runs.
    SWEPT=$(B sections archive | sed -n 's/^archived \([0-9][0-9]*\) tab.*/\1/p')
    [ -n "$SWEPT" ] || fail "the Today sweep did not run in space $i"
    [ "$SWEPT" = 0 ] || fail "the Today sweep closed $SWEPT imported tabs in space $i"
  done
  AFTER=$(B flow spaces | jq '[.spaces[].tabs] | add')
  [ "$AFTER" = "$BEFORE" ] || fail "tabs went missing after showing every space ($BEFORE → $AFTER)"
  ok "Arc copy: $MADE spaces, $TABS tabs; every space shown and swept, $AFTER tabs still there"
  SECOND=$(B flow move --source Arc --only tabs 2>/dev/null)
  printf '%s\n' "$SECOND" | jq -r '.summary[]' | sed 's/^/     /'
  check "second Arc move adds nothing" '.tabs == 0 and .spacesMade == 0' "$SECOND"
  [ "$(B flow spaces | jq '.spaces | length')" = "$SPACES1" ] || fail "second Arc move changed the spaces"
  B flow spaces | jq -e '[.spaces[] | select(.name | test("\\(Arc\\)"))] | length == 0' >/dev/null || fail "a duplicate (Arc) space exists"
  ok "second Arc move: no space made, no tab added, no (Arc) names"
  quit
fi
echo "ok: flow move end to end"
