#!/bin/bash
# Agent safety gates, end to end over MCP, against nobody's vault: a fresh
# headless probe world whose keychain is a file and whose 1Password is the
# mock CLI (docs/fixtures/op-mock/op), and pages served from 127.0.0.1 with
# a frame from localhost — another origin.
#
#   1. A 1Password card in a vault named Agents counts as shared with
#      agents, with "share all" off: browser_autofill kind=card fills it.
#   2. Focus spoof: a cross-origin frame posts "the caret is in me" before
#      browser_sign_in. The page's account (127.0.0.1) never reaches the
#      frame; the call is refused and nothing is filled anywhere.
#   3. The page's own sign-in, caret back on the page: filled, frame still empty.
#   4. A one-time code: filled and its own form sent (submitted: true).
#   5. Close, then call: the agent closes its own tab. Page-changing
#      calls (navigate, evaluate, close, tabs close) are refused with "your
#      tab was closed" and the user's tab is untouched; a read (snapshot)
#      still reads the tab on screen; browser_tabs new gets a tab again.
#   6. An agent that never had a tab can't browser_close the user's tab.
#
# COPPER_APP=/path/Copper.app runs another build (COPPER_KEEP_GOING=1 for all steps).
# Ports: MCP $COPPER_MCP_PORT (4170), pages $FIXTURE_PORT (4171).
#   COPPER_SKIP_BUILD=1 docs/fixtures/agent-safety-e2e.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="safety-$$"
suite="com.collinrijock.copper.test.$world"
folder="$HOME/Library/Application Support/Copper ($world)"
mcp_port="${COPPER_MCP_PORT:-4170}"
port="${FIXTURE_PORT:-4171}"
tmp="$(mktemp -d)"
pid="" server=""
export OP_MOCK_STATE="$tmp/op/state.json"
mkdir -p "$tmp/op"
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  defaults delete "$suite" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0 seen=0
# COPPER_KEEP_GOING=1 runs every step and reports each failure (for an old build).
fail() { echo "FAIL $*"; [ "${COPPER_KEEP_GOING:-0}" = 1 ] && { failed=$((failed + 1)); return 0; }; exit 1; }
step() { if [ "$failed" = "$seen" ]; then echo "ok $*"; else echo "not ok $*"; fi; seen=$failed; }
bench() { "$root/bench" --world "$world" "$@"; }
op() { python3 "$root/docs/fixtures/op-mock/op" "$@"; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

python3 - "$port" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, sys
pages = {
  # The page signs in at 127.0.0.1; its frame comes from localhost and says
  # what its boxes hold (the password's length only), and on "spoof" tells
  # Copper the caret is in it — any page can post that message.
  '/spoof': b'''<!doctype html><meta charset="utf-8"><title>Victim</title>
<form id="f"><input id="user" name="username" type="email" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password"></form>
<p id="evil">nothing</p><iframe id="fr" style="width:420px;height:200px"></iframe>
<script>document.getElementById('fr').src = 'http://localhost:' + location.port + '/evil';
addEventListener('message', (e) => { if (e.data && e.data.evil !== undefined) document.getElementById('evil').textContent = JSON.stringify(e.data); });
document.getElementById('f').addEventListener('submit', (e) => e.preventDefault());</script>''',
  '/evil': b'''<!doctype html><meta charset="utf-8"><title>Frame</title>
<form id="f"><input id="user" type="email" autocomplete="username"><input id="pass" type="password" autocomplete="current-password"></form>
<script>const tell = () => parent.postMessage({ evil: document.getElementById('user').value, len: document.getElementById('pass').value.length }, '*');
document.addEventListener('input', tell, true); setInterval(tell, 200);
document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); tell(); });
addEventListener('message', (e) => { if (e.data === 'spoof') webkit.messageHandlers.officeForms.postMessage(
  { kind: 'focus', typing: true, rect: { x: 10, y: 10, width: 200, height: 24 }, field: null, hint: '' }); });</script>''',
  '/code': b'''<!doctype html><meta charset="utf-8"><title>Code</title>
<form id="f"><label>Verification code <input id="otp" name="otp" inputmode="numeric" autocomplete="one-time-code"></label></form>
<script>document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); document.title = 'sent ' + document.getElementById('otp').value.length; });</script>''',
  '/card': b'''<!doctype html><meta charset="utf-8"><title>Pay</title>
<form id="f"><input id="num" name="cardnumber" autocomplete="cc-number"><input id="name" name="ccname" autocomplete="cc-name">
<input id="exp" name="exp" autocomplete="cc-exp"><input id="csc" name="cvc" autocomplete="cc-csc"></form>''',
  '/user': b'''<!doctype html><meta charset="utf-8"><title>User page</title><p>The user's own tab.</p>''',
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = pages.get(self.path.split('?')[0])
        self.send_response(200 if body else 404)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(body or b'')
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
server=$!
for _ in {1..40}; do curl -fsS -o /dev/null "http://127.0.0.1:$port/user" 2>/dev/null && break; sleep 0.1; done
curl -fsS -o /dev/null "http://127.0.0.1:$port/user" || fail "page server on $port"
base="http://127.0.0.1:$port"

op mock reset >/dev/null
# The card's vault is named Agents: sharing by folder, as a login's is.
python3 - "$OP_MOCK_STATE" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for v in d["vaults"]:
    if v["name"] == "Shared": v["name"] = "Agents"
json.dump(d, open(p, "w"))
PY

mkdir -p "$folder"
token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
printf '{"enabled":true,"port":%s,"token":"%s","announces":false,"jev":false}' "$mcp_port" "$token" >"$folder/agent.json"
defaults write "$suite" bench -bool true
defaults write "$suite" welcomed -bool true
defaults write "$suite" probe.keychain -string file
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="$mcp_port" SEARCH_OP_PATH="$root/docs/fixtures/op-mock/op" SEARCH_OP_APP_PATH=none \
  "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

json() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1"; }
# One MCP call as agent session $1: prints "ok|err<TAB>text".
mcp() {
  local raw
  raw=$(curl -s -m 30 -X POST "http://127.0.0.1:$mcp_port/mcp" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3,\"_meta\":{\"copper/agent\":{\"session\":\"$1\",\"label\":\"e2e $1\"}}}}")
  python3 -c '
import json, sys
raw = sys.argv[1]
line = next((l[5:] for l in raw.splitlines() if l.startswith("data:")), raw)
r = json.loads(line).get("result", {})
text = " ".join(c.get("text", "") for c in r.get("content", []))
print(("err" if r.get("isError") else "ok") + "\t" + text.replace("\n", " "))' "$raw"
}
ok() { [ "${1%%$'\t'*}" = ok ]; }
eval_in() { bench eval "$1" "$2" 2>/dev/null || true; }
wait_eval() { # ID JS-returning-true TRIES
  for _ in $(seq 1 "${3:-60}"); do [ "$(eval_in "$1" "$2")" = true ] && return 0; sleep 0.1; done
  return 1
}
wait_step() {
  local st
  for _ in {1..100}; do
    st=$(bench op status)
    case "$(json "$st" "d.get('step','')")" in "$1:ok") return 0;; "$1:failed") fail "$1: $st";; esac
    sleep 0.1
  done
  fail "$1 never ended: $st"
}
tab_of() { grep -oE '\{tab [0-9a-f]{8}\}' <<<"$1" | head -1 | grep -oE '[0-9a-f]{8}'; }

# --- 1. A card in the Agents vault is shared --------------------------------
bench op accounts >/dev/null; wait_step accounts
bench op signin password correct horse battery staple >/dev/null; wait_step signin-password
for _ in {1..50}; do [ "$(json "$(bench op cards)" "len(d.get('cards', []))")" != 0 ] && break; sleep 0.1; done
cards=$(bench op cards)
[ "$(json "$cards" "[c['agent'] for c in d['cards'] if c['name']=='Visa Personal'][0]")" = True ] \
  || fail "the card in the Agents vault isn't shared with agents: $cards"
out=$(mcp card browser_tabs "{\"action\":\"new\",\"url\":\"$base/card\"}")
ok "$out" || fail "card tab: $out"
ct=$(tab_of "$out")
wait_eval "$ct" "document.readyState === 'complete' && !!window.__officeForms" || fail "card page"
out=$(mcp card browser_autofill '{"kind":"card"}')
ok "$out" || fail "card in the Agents vault refused: $out"
wait_eval "$ct" "document.getElementById('num').value.length === 16" 30 || fail "card not filled: $out"
step "1 a card in the Agents vault is shared with agents and fills (share-all off)"
bench op signout >/dev/null; wait_step signout

# --- 2. A frame that claims the caret gets nothing ---------------------------
printf 'url,username,password,otpauth\n%s/spoof,alice,synthetic-pw,otpauth://totp/Synthetic:alice?secret=JBSWY3DPEHPK3PXP&digits=6&period=30\n' "$base" >"$tmp/logins.csv"
bench passwords import "$tmp/logins.csv" >/dev/null
for _ in {1..40}; do
  [ "$(json "$(bench bw candidates 127.0.0.1)" "len(d['candidates'])")" = 1 ] && break; sleep 0.1
done
bench op share all on >/dev/null
out=$(mcp a browser_tabs "{\"action\":\"new\",\"url\":\"$base/spoof\"}")
ok "$out" || fail "agent tab: $out"
at=$(tab_of "$out")
[ -n "$at" ] || fail "no tab id in $out"
wait_eval "$at" "document.getElementById('evil').textContent.indexOf('\"len\":0') >= 0" 80 || fail "frame never loaded"
bench eval "$at" "document.getElementById('fr').contentWindow.postMessage('spoof', '*'); 1" >/dev/null
sleep 0.6
out=$(mcp a browser_sign_in '{"account":"alice","submit":false}')
sleep 0.8
said=$(eval_in "$at" "document.getElementById('evil').textContent")
page=$(eval_in "$at" "document.getElementById('pass').value.length")
echo "   sign-in: $out"
echo "   frame says $said; page password length $page"
grep -q '"len":0' <<<"$said" || fail "the page's password reached the cross-origin frame ($said)"
grep -q 'alice' <<<"$said" && fail "the page's account name reached the frame ($said)"
ok "$out" && fail "sign-in with a spoofed frame focus succeeded: $out"
[ "$page" = 0 ] || fail "filled the page while the caret was claimed by a frame ($page)"
step "2 a cross-origin frame that posts focus gets nothing (${out#*$'\t'})"

# --- 3. The page's own sign-in ----------------------------------------------
bench eval "$at" "document.getElementById('user').focus(); 1" >/dev/null
sleep 0.4
out=$(mcp a browser_sign_in '{"account":"alice","submit":false}')
ok "$out" || fail "the page's own sign-in: $out"
grep -q 'synthetic-pw' <<<"$out" && fail "the password is in the answer"
wait_eval "$at" "document.getElementById('pass').value.length === 12" 30 || fail "page not filled: $out"
grep -q '"len":0' <<<"$(eval_in "$at" "document.getElementById('evil').textContent")" || fail "the frame got the password"
step "3 the caret on the page: the page's account fills the page, not the frame"

# --- 4. A one-time code is sent ---------------------------------------------
out=$(mcp a browser_navigate "{\"url\":\"$base/code\"}")
ok "$out" || fail "navigate to code page: $out"
wait_eval "$at" "document.readyState === 'complete' && !!window.__officeForms" || fail "code page"
out=$(mcp a browser_sign_in '{"account":"alice","what":"otp"}')
ok "$out" || fail "otp sign-in: $out"
grep -q '"submitted":true' <<<"$out" || fail "the code was filled but not sent: $out"
wait_eval "$at" "document.title === 'sent 6'" 30 || fail "the code form wasn't submitted (title $(eval_in "$at" document.title))"
step "4 a one-time code fills and sends its own form"

# --- 5. Close, then call -----------------------------------------------------
ut=$(bench open "$base/user" | grep -oE '[0-9a-f]{8}' | head -1)
[ -n "$ut" ] || fail "no user tab"
bench wait "$ut" 10 >/dev/null
bench select "$ut" >/dev/null
out=$(mcp a browser_close '{}')
ok "$out" || fail "the agent closing its own tab: $out"
bench tabs | grep -q "$at" && fail "the agent's tab is still open"
user_ok() { [ "$(eval_in "$ut" "location.pathname + '|' + document.title")" = "/user|User page" ] || fail "the user's tab was changed: $(eval_in "$ut" "location.href + '|' + document.title")"; }
for call in "browser_navigate {\"url\":\"$base/code\"}" "browser_evaluate {\"function\":\"() => { document.title = 'hacked'; return 1 }\"}" \
            "browser_close {}" "browser_tabs {\"action\":\"close\"}"; do
  out=$(mcp a ${call%% *} "${call#* }")
  ok "$out" && fail "${call%% *} after the agent's tab closed was not refused: $out"
  grep -q 'your tab was closed' <<<"$out" || fail "${call%% *} refused without saying why: $out"
  user_ok
done
bench tabs | grep -q "$ut" || fail "the user's tab was closed"
out=$(mcp a browser_snapshot '{}')
ok "$out" || fail "a read after the close was refused: $out"
grep -q 'User page' <<<"$out" || fail "the read didn't read the tab on screen: $out"
out=$(mcp a browser_tabs "{\"action\":\"new\",\"url\":\"$base/code\"}")
ok "$out" || fail "a new tab after the close: $out"
out=$(mcp a browser_navigate "{\"url\":\"$base/card\"}")
ok "$out" || fail "navigate in the new tab: $out"
user_ok
step "5 the agent's tab closed: navigate/evaluate/close refused, user's tab untouched, snapshot reads it, browser_tabs new works again"

# --- 6. An agent that never had a tab can't close the user's -----------------
out=$(mcp b browser_close '{}')
ok "$out" && fail "browser_close from an agent with no tab closed something: $out"
bench tabs | grep -q "$ut" || fail "the user's tab was closed by an agent with no tab"
step "6 browser_close from an agent with no tab of its own refuses (${out#*$'\t'})"
[ "$failed" = 0 ] || exit 1
echo PASS
