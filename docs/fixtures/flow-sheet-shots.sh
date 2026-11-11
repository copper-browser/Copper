#!/bin/bash
# Pictures of every Move-in sheet state, light and dark, and a watch on its
# frame while it goes from one state to the next. For review, not a gate:
# it fails only when a state can't be reached or the frame moves.
#
#   docs/fixtures/flow-sheet-shots.sh OUTDIR [build/Copper.app]
#
# States (OUTDIR/NN-state-{light,dark}.png): locked; locked beside a
# readable source; installed but never opened; preview; export pane; export
# with a result; moving; done; done with reasons; nothing new; moved before
# ("Move in again"); undone; and the picker and done in a 640×420 window.
# OUTDIR/frames.txt is every (phase, sheet size) seen at ~20 Hz from open to
# done; the script fails if the size changes.
#
# Fresh headless worlds, generated fixtures (a Chrome profile, and an Arc
# sidebar with one space for a second card), never a real browser folder,
# never the keychain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: $0 OUTDIR [APP]}"
APP=${2:-"$ROOT/build/Copper.app"}
[ -x "$APP/Contents/MacOS/Copper" ] || { echo "FAIL: build Copper first (./build.sh)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }
mkdir -p "$OUT"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-shots.XXXXXX")
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
fail() { echo "FAIL: $*" >&2; exit 1; }
WORLD=""
B() { "$ROOT/bench" --world "$WORLD" "$@"; }
until_state() {
  local state
  for _ in $(seq 1 100); do
    state=$(B flow state)
    if printf '%s\n' "$state" | jq -e "$1" >/dev/null; then return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $1: $state"
}
N=0
shot() {
  N=$((N + 1))
  local name; name=$(printf '%02d-%s' "$N" "$1")
  for look in light dark; do
    B ui look "$look" >/dev/null
    sleep 0.4
    B flow shot --path "$OUT/$name-$look.png" >/dev/null || fail "shot $name $look"
  done
  B ui look light >/dev/null
  echo "ok: $name"
}
launch() { # launch NAME SIZE
  WORLD="flowshots$1$(date +%s)$$"
  WORLDS+=("$WORLD")
  local port=$((46000 + ($$ + ${#WORLDS[@]}) % 9000))
  defaults write "com.collinrijock.copper.test.$WORLD" bench -bool true
  defaults write "com.collinrijock.copper.test.$WORLD" welcomed -bool true
  defaults write "com.collinrijock.copper.test.$WORLD" flow.installed -string "Chrome"
  open -n -g --stderr "$TEMP/$1.log" --env SEARCH_PROBE="$WORLD" --env SEARCH_HEADLESS=1 \
    --env SEARCH_MCP_PORT="$port" --env SEARCH_HEADLESS_SIZE="$2" "$APP"
  local pid=""
  for _ in $(seq 1 120); do
    pid=$(sed -n 's/.*on — pid \([0-9][0-9]*\).*/\1/p' "$TEMP/$1.log" 2>/dev/null | head -1)
    [ -n "$pid" ] && B tabs >/dev/null 2>&1 && break
    sleep 0.5
  done
  [ -n "$pid" ] || fail "headless probe $1 did not start"
  PIDS+=("$pid")
}
profile() { # profile ROOT URL…
  local root="$1"; shift
  mkdir -p "$root/Default/Sessions"
  printf '{"profile":{"name":"Default"}}\n' > "$root/Default/Preferences"
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
  ' "$@" > "$root/Default/Sessions/Current Session"
  printf '{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[{"type":"url","name":"A","url":"https://alpha.invalid/"}]},"other":{"type":"folder","name":"Other","children":[]},"synced":{"type":"folder","name":"Mobile","children":[]}},"version":1}\n' > "$root/Default/Bookmarks"
}
profile "$TEMP/Chrome" "https://alpha.invalid/one" "https://alpha.invalid/two"
mkdir -p "$TEMP/Arc/User Data/Default"
printf '{"profile":{"name":"Default"}}\n' > "$TEMP/Arc/User Data/Default/Preferences"
cat > "$TEMP/Arc/StorableSidebar.json" <<'JSON'
{"sidebar":{"containers":[{"global":{}},{"spaces":[{"id":"S1","title":"Research","containerIDs":["pinned","P1","unpinned","U1"]}],
"items":[{"id":"P1","childrenIds":[],"data":{}},{"id":"U1","childrenIds":["T1"],"data":{}},
{"id":"T1","title":"Beta","childrenIds":[],"data":{"tab":{"savedURL":"https://beta.invalid/one","savedTitle":"Beta"}}}],
"topAppsContainerIDs":[]}]}}
JSON
mkdir -p "$TEMP/Empty"
printf '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p><DT><A HREF="https://exported.invalid/a">A</A></DL>\n' > "$TEMP/bookmarks.html"

# ---- 1440×960
launch wide 1440x960
B flow limit --only Chrome >/dev/null
B flow access --source Chrome locked >/dev/null
B flow root --source Chrome --path "$TEMP/Chrome" >/dev/null
B flow open >/dev/null
until_state '.showing and .sourcesKnown'
shot locked
B flow close >/dev/null; until_state '.showing | not'

B flow limit --only Chrome,Arc >/dev/null
B flow root --source Arc --path "$TEMP/Arc/User Data" >/dev/null
B flow open >/dev/null
until_state '.showing and .phase == "preview"'
shot locked-and-readable
B flow close >/dev/null; until_state '.showing | not'

B flow limit --only Chrome >/dev/null
B flow root --source Chrome --path "$TEMP/Empty" >/dev/null || :
B flow access --source Chrome clear >/dev/null
B flow open >/dev/null
until_state '.showing and .sourcesKnown and (.sources[0].empty)'
shot installed-never-opened
B flow close >/dev/null; until_state '.showing | not'

B flow root --source Chrome --path "$TEMP/Chrome" >/dev/null
B flow access --source Chrome locked >/dev/null
B flow open >/dev/null
until_state '.showing and .sourcesKnown'
B flow export --source Chrome >/dev/null
until_state '.exporting == "Chrome"'
shot export
B flow file --path "$TEMP/bookmarks.html" >/dev/null
shot export-result
B flow back >/dev/null
B flow access --source Chrome clear >/dev/null
B flow activate >/dev/null
until_state '.phase == "preview"'
shot preview

# The frame, from here to done, at ~20 Hz.
python3 - "$HOME/Library/Application Support/Copper ($WORLD)/bench.sock" "$OUT/frames.txt" <<'PY' &
import json, socket, sys, time
path, out = sys.argv[1], sys.argv[2]
seen = []
end = time.time() + 30
while time.time() < end:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(path)
            s.sendall(b'{"do":"flow","op":"state"}\n')
            data = b""
            while True:
                chunk = s.recv(65536)
                if not chunk: break
                data += chunk
        st = json.loads(data.split(b"\n", 1)[0] or b"{}")
        row = f'{st.get("phase")} {st.get("sheet")} sheets={st.get("attachedSheets")}'
        if not seen or seen[-1] != row: seen.append(row)
        if st.get("phase") == "done":
            break
    except Exception as e:
        pass
    time.sleep(0.05)
open(out, "w").write("\n".join(seen) + "\n")
PY
WATCH=$!
B flow slow --seconds 0.8 >/dev/null
B flow choose --only tabs,bookmarks,history,passwords,cookies,passkeys >/dev/null
B flow key return >/dev/null
until_state '.phase == "moving" and ((.lines // []) | length) >= 1'
shot moving
until_state '.phase == "done"'
wait "$WATCH" || :
B flow slow --seconds 0 >/dev/null
shot done-with-reasons
SIZES=$(awk '{print $2 $3}' "$OUT/frames.txt" | sort -u | wc -l | tr -d ' ')
[ "$SIZES" = 1 ] || fail "the sheet's size changed between phases: $(tr '\n' ';' < "$OUT/frames.txt")"
echo "ok: frame held at $(awk 'NR==1{print $2 $3}' "$OUT/frames.txt") through $(awk '{print $1}' "$OUT/frames.txt" | uniq | tr '\n' ' ')"
B flow undo >/dev/null
shot undone
B flow close >/dev/null; until_state '.showing | not'

B flow open >/dev/null
until_state '.showing and .phase == "preview"'
shot moved-before
B flow close >/dev/null; until_state '.showing | not'

B flow open --again >/dev/null
until_state '.showing and .phase == "preview"'
B flow choose --only tabs,bookmarks >/dev/null
B flow key return >/dev/null
until_state '.phase == "done"'
shot done
B flow close >/dev/null; until_state '.showing | not'
B flow open --again >/dev/null
until_state '.showing and .phase == "preview"'
B flow choose --only tabs,bookmarks >/dev/null
B flow key return >/dev/null
until_state '.phase == "done"'
shot nothing-new
B windows quit >/dev/null || :

# ---- 640×420
launch small 640x420
B flow limit --only Chrome >/dev/null
B flow root --source Chrome --path "$TEMP/Chrome" >/dev/null
B flow open >/dev/null
until_state '.showing and .phase == "preview"'
B flow state | jq -c '{sheet, hostSize}' > "$OUT/small-frame.json"
shot small-preview
B flow choose --only tabs,bookmarks >/dev/null
B flow key return >/dev/null
until_state '.phase == "done"'
shot small-done
B windows quit >/dev/null || :
echo "ok: shots in $OUT"
