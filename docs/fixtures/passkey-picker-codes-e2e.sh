#!/bin/bash
# The account list in real WebKit: a conditional passkey sign-in answered by
# picking its row, and a keychain login whose two-step code fills itself on
# the code page after the login is picked. A fresh headless dev world whose
# keychain is the probe file stand-in (no keychain item, no Touch ID, no
# account, no network beyond one localhost page).
#   COPPER_SKIP_BUILD=1 docs/fixtures/passkey-picker-codes-e2e.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="pkcodes-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""; server=""
bench() { "$root/bench" --world "$world" "$@"; }
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { echo "FAIL $*"; exit 1; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && swift build -c release --jobs 4 && SEARCH_SIGN_IDENTITY=- ./build.sh)
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"

python3 - "$tmp/port" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, pathlib, sys
pages = {
  '/pk': b'''<!doctype html><meta charset="utf-8"><title>Passkey list</title>
<form><input id="who" name="username" autocomplete="username webauthn"></form>''',
  '/login': b'''<!doctype html><meta charset="utf-8"><title>Sign in</title>
<div id="box"><form id="f" onsubmit="event.preventDefault(); step();">
<input id="user" name="username" type="text" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password">
<button>Sign in</button></form></div>
<script>function step() { document.getElementById('box').innerHTML =
 '<form><label>Verification code <input id="otp" name="otp" inputmode="numeric" autocomplete="one-time-code"></label></form>'; }</script>''',
}
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = pages.get(self.path.split('?')[0], b'<!doctype html><p>synthetic')
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
server=$!
for _ in {1..40}; do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || fail "localhost server"
port=$(<"$tmp/port")

suite="com.officecommun.search.test.$world"
defaults write "$suite" bench -bool true
defaults write "$suite" welcomed -bool true
defaults write "$suite" probe.keychain -string file
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null || fail "headless bench"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["probeKeychain"]' "$(bench passwords status)" || fail "probe keychain not active"
bench passkeys answer yes >/dev/null

json() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1"; }
wait_eval() { # ID JS-returning-truthy TRIES
  local out
  for _ in $(seq 1 "${3:-60}"); do
    out=$(bench eval "$1" "$2" 2>/dev/null || true)
    [ "$out" = true ] && return 0
    sleep 0.1
  done
  return 1
}

# --- 1. A conditional passkey sign-in, answered from the list -------------
pk=$(bench open "http://localhost:$port/pk")
wait_eval "$pk" "document.readyState === 'complete' && !!window.__copperPasskeys" || fail "passkey page/bridge"
bench eval "$pk" "window.__made = null; navigator.credentials.create({publicKey: {challenge: new Uint8Array([1]),
  rp: {id: 'localhost', name: 'Synthetic'}, user: {id: new Uint8Array([7]), name: 'synthetic-pk', displayName: 'Synthetic'},
  pubKeyCredParams: [{type: 'public-key', alg: -7}]}}).then(c => window.__made = c.id, e => window.__made = 'error:' + e.name); 'ok'" >/dev/null
wait_eval "$pk" "!!window.__made" || fail "create did not finish"
made=$(bench eval "$pk" "window.__made")
case "$made" in error:*) fail "create: $made";; esac
bench eval "$pk" "window.__avail = null; PublicKeyCredential.isConditionalMediationAvailable().then(v => window.__avail = v); 'asked'" >/dev/null
wait_eval "$pk" "window.__avail === true" 20 || fail "conditional reported unavailable: $(bench eval "$pk" 'String(window.__avail)')"
bench eval "$pk" "window.__cond = null; navigator.credentials.get({mediation: 'conditional', publicKey: {challenge: new Uint8Array([9,9])}})
  .then(c => window.__cond = {id: c.id, user: !!c.response.userHandle}, e => window.__cond = {error: e.name}); 'waiting'" >/dev/null
sleep 0.5
bench eval "$pk" "window.__cond === null" | grep -q true || fail "conditional get answered before a pick: $(bench eval "$pk" 'JSON.stringify(window.__cond)')"
bench select "$pk" >/dev/null
bench eval "$pk" "document.getElementById('who').blur(); document.getElementById('who').focus(); 'focused'" >/dev/null
row=""
for _ in {1..40}; do
  rows=$(bench bw rows 2>/dev/null || true)
  row=$(python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: sys.exit()
print(next((r for r in d.get("rows", []) if r.startswith("passkey:")), ""))' "$rows")
  [ -n "$row" ] && break
  sleep 0.1
done
[ -n "$row" ] || fail "no passkey row under the box: $rows"
[ "$row" = "passkey:$made" ] || fail "row $row is not the passkey made ($made)"
bench bw pick "$row" >/dev/null
wait_eval "$pk" "!!window.__cond" || fail "conditional get never answered"
cond=$(bench eval "$pk" "JSON.stringify(window.__cond)")
python3 -c 'import json,sys; c=json.loads(sys.argv[1]); c=json.loads(c) if isinstance(c, str) else c; assert c.get("id")==sys.argv[2] and c.get("user"), c' "$cond" "$made" \
  || fail "conditional result $cond"
echo "PASS passkey: conditional get waited, its row ($row) led the list, the pick answered it"

# --- 2. A keychain login with a two-step code ------------------------------
seed=JBSWY3DPEHPK3PXP
printf 'url,username,password,otpauth\nhttp://localhost:%s/login,alice,synthetic-pw,otpauth://totp/Synthetic:alice?secret=%s&digits=6&period=30\n' "$port" "$seed" >"$tmp/logins.csv"
bench passwords import "$tmp/logins.csv" >/dev/null
for _ in {1..40}; do
  st=$(bench passwords status)
  [ "$(json "$st" "(d.get('lastImport') or {}).get('kept', -1)")" != -1 ] && break
  sleep 0.1
done
[ "$(json "$st" "d['lastImport']['codes']")" = 1 ] || fail "import kept no code: $st"
cands=$(bench bw candidates localhost)
[ "$(json "$cands" "[c['totp'] for c in d['candidates'] if c['user']=='alice'][0]")" = True ] || fail "alice has no code: $cands"

lg=$(bench open "http://localhost:$port/login")
wait_eval "$lg" "document.readyState === 'complete' && !!window.__officeForms" || fail "login page"
bench select "$lg" >/dev/null
bench eval "$lg" "document.getElementById('user').focus(); 'focused'" >/dev/null
krow=""
for _ in {1..40}; do
  rows=$(bench bw rows 2>/dev/null || true)
  krow=$(python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: sys.exit()
print(next((r for r in d.get("rows", []) if r.startswith("kc:")), ""))' "$rows")
  [ -n "$krow" ] && break
  sleep 0.1
done
[ -n "$krow" ] || fail "no keychain row: $rows"
bench bw pick "$krow" >/dev/null
wait_eval "$lg" "document.getElementById('pass') && document.getElementById('pass').value === 'synthetic-pw'" || fail "password not filled"
bench eval "$lg" "step(); 'code page'" >/dev/null
wait_eval "$lg" "!!document.getElementById('otp') && document.getElementById('otp').value.length === 6" 50 \
  || fail "code box not filled on its own: $(bench eval "$lg" "document.getElementById('otp') && document.getElementById('otp').value")"
code=$(bench eval "$lg" "document.getElementById('otp').value" | tr -d '"')
python3 - "$seed" "$code" <<'PY' || fail "filled code $code is not the account's TOTP"
import base64, hmac, hashlib, struct, sys, time
key = base64.b32decode(sys.argv[1]); now = int(time.time()) // 30
codes = []
for step in (now - 1, now, now + 1):
    mac = hmac.new(key, struct.pack('>Q', step), hashlib.sha1).digest()
    o = mac[-1] & 15
    codes.append('%06d' % ((struct.unpack('>I', mac[o:o+4])[0] & 0x7fffffff) % 1000000))
assert sys.argv[2] in codes, (sys.argv[2], codes)
PY
echo "PASS codes: CSV kept the key, the picked login filled, the code page filled itself with the right TOTP ($code)"
