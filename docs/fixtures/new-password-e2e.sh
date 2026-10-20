#!/bin/bash
# "Suggest strong password" in real WebKit, against nobody's vault: a fresh
# headless dev world whose keychain is the probe file stand-in and whose
# 1Password is the mock CLI (docs/fixtures/op-mock/op), and localhost pages
# shaped like the forms that need it:
#
#   /login    a plain sign-in            → no strong-password row
#   /signup   autocomplete=new-password on both boxes, passwordrules
#             (12–16 chars, max-consecutive 2) → row, both boxes filled to
#             the rules, the login made in 1Password before submit, no
#             second save offer after it
#   /change   a change form with no labels or hints, only the names
#             OldPass / Pass1 / Pass2 (UKG's) → the saved login's current
#             password in OldPass (read before the update), the new one in
#             Pass1 and Pass2, the 1Password item updated in place
#   /change   again with the keychain as the target → filled, the keychain
#             left alone until the change is sent, then an Update offer for
#             the right account that writes the new password when kept
#   typed     a sign-up typed by hand → a Save offer with the new password
#             and its account; a change typed by hand on a form that names no
#             account, followed by a sign-in form → an Update offer for the
#             only login kept for the site
#   agents    browser_autofill kind=new-password refuses a login not shared
#             with agents (nothing filled), then with it shared saves and
#             fills without the password in its answer; `copper autofill
#             new-password --account --submit` makes a sign-up's login
#
# Every password is checked by comparison (op mock check, bench passwords
# check) — none is printed. COPPER_SHOTS=DIR keeps pictures of the list and
# the filled forms there.
#   COPPER_SKIP_BUILD=1 docs/fixtures/new-password-e2e.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="newpw-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""; server=""
export OP_MOCK_STATE="$tmp/op/state.json"
mkdir -p "$tmp/op"
bench() { "$root/bench" --world "$world" "$@"; }
op() { python3 "$root/docs/fixtures/op-mock/op" "$@"; }
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
  (cd "$root" && SEARCH_SIGN_IDENTITY=- ./build.sh)
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"

python3 - "$tmp/port" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, pathlib, sys
done = b'''<script>function sent(e) { e.preventDefault(); document.getElementById('f').remove();
document.body.insertAdjacentHTML('beforeend', location.search.indexOf('then=login') >= 0
  ? '<form id="again"><input name="username" type="email"><input name="password" type="password"></form>'
  : '<p id="ok">Saved</p>'); }
document.getElementById('f').addEventListener('submit', sent);</script>'''
pages = {
  '/login': b'''<!doctype html><meta charset="utf-8"><title>Sign in</title>
<form id="f"><input id="user" name="username" type="email" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password"><button>Sign in</button></form>''' + done,
  '/signup': b'''<!doctype html><meta charset="utf-8"><title>Create account</title>
<form id="f"><label>Email <input id="email" name="email" type="email"></label>
<label>Password <input id="new" name="password" type="password" autocomplete="new-password"
  passwordrules="required: upper; required: lower; required: digit; max-consecutive: 2; minlength: 12; maxlength: 16;"></label>
<label>Confirm password <input id="again" name="password2" type="password" autocomplete="new-password"></label>
<button>Create account</button></form>''' + done,
  '/change': b'''<!doctype html><meta charset="utf-8"><title>Change password</title>
<p>Signed in as ACCOUNT</p>
<form id="f"><table>
<tr><td>Old Password</td><td><input type="password" name="OldPass" id="OldPass" maxlength="65"></td></tr>
<tr><td>New Password</td><td><input type="password" name="Pass1" id="Pass1" maxlength="65"></td></tr>
<tr><td>Confirm New Password</td><td><input type="password" name="Pass2" id="Pass2" maxlength="65"></td></tr>
</table><button>Save</button></form>''' + done,
}
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path, _, query = self.path.partition('?')
        data = pages.get(path, b'<!doctype html><p>synthetic')
        data = data.replace(b'ACCOUNT', (query.partition('=')[2] or 'nobody').encode())
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
op mock reset >/dev/null

suite="com.officecommun.search.test.$world"
defaults write "$suite" bench -bool true
defaults write "$suite" welcomed -bool true
defaults write "$suite" probe.keychain -string file
mcp_port=$((41000 + $$ % 9000))
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_MCP_PORT="$mcp_port" SEARCH_OP_PATH="$root/docs/fixtures/op-mock/op" SEARCH_OP_APP_PATH=none \
  "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null || fail "headless bench"

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
wait_step() { # NAME — until `op status` says it ended
  local st
  for _ in {1..100}; do
    st=$(bench op status)
    case "$(json "$st" "d.get('step','')")" in "$1:ok") return 0;; "$1:failed") fail "$1: $st";; esac
    sleep 0.1
  done
  fail "$1 never ended: $st"
}
rows_of() { bench op rows 2>/dev/null || echo '{}'; }
# The list under the box once it has drawn: its rows, as JSON.
rows_after_focus() { # ID SELECTOR
  local rows=""
  bench select "$1" >/dev/null
  bench eval "$1" "document.querySelector('$2').blur(); document.querySelector('$2').focus(); 'focused'" >/dev/null
  sleep 0.4
  for _ in {1..40}; do
    rows=$(rows_of)
    [ "$(json "$rows" "len(d.get('rows', []))")" != 0 ] && break
    sleep 0.1
  done
  echo "$rows"
}
value() { bench eval "$1" "document.querySelector('$2').value"; }
shots() { [ -n "${COPPER_SHOTS:-}" ]; }
shot_list() { shots && bench render picker-live "$COPPER_SHOTS/$1.png" >/dev/null || true; }
shot_page() { shots && bench shot "$1" "$COPPER_SHOTS/$2.png" >/dev/null || true; }

bench op accounts >/dev/null
wait_step accounts
bench op signin password correct horse battery staple >/dev/null
wait_step signin-password
bench op backend onepassword >/dev/null
[ "$(json "$(bench op status)" "d['saveTarget']")" = onepassword ] || fail "1Password is not the save target: $(bench op status)"

# --- 1. A sign-in is not offered a new password ----------------------------
lg=$(bench open "http://localhost:$port/login")
wait_eval "$lg" "document.readyState === 'complete' && !!window.__officeForms" || fail "login page"
bench eval "$lg" "document.getElementById('user').value = 'alice@example.com'; 'typed'" >/dev/null
rows=$(rows_after_focus "$lg" "#pass")
json "$rows" "'new-password' not in d.get('rows', [])" | grep -q True || fail "sign-in offered a new password: $rows"
echo "PASS sign-in: no strong-password row ($(json "$rows" "len(d['rows'])") saved accounts)"
bench close "$lg" >/dev/null

# --- 2. Sign-up with passwordrules ------------------------------------------
su=$(bench open "http://localhost:$port/signup")
wait_eval "$su" "document.readyState === 'complete' && !!window.__officeForms" || fail "signup page"
bench eval "$su" "(() => { const e = document.getElementById('email'); e.focus(); e.value = 'dana@example.com';
  e.dispatchEvent(new Event('input', {bubbles: true})); return 'typed'; })()" >/dev/null
rows=$(rows_after_focus "$su" "#new")
[ "$(json "$rows" "d['rows'][0]")" = new-password ] || fail "sign-up list does not lead with the strong password: $rows"
[ "$(json "$rows" "len(d['rows'])")" = 1 ] || fail "sign-up list holds saved accounts too: $rows"
case "$(json "$rows" "d.get('footer')")" in *1Password*) ;; *) fail "footer: $rows";; esac
shot_list signup-list
bench op pick new-password >/dev/null
wait_eval "$su" "(() => { const a = document.getElementById('new').value, b = document.getElementById('again').value;
  return a.length === 16 && a === b && /[a-z]/.test(a) && /[A-Z]/.test(a) && /[0-9]/.test(a) && !/(.)\\1\\1/.test(a); })()" \
  || fail "sign-up boxes not filled to the rules (16, upper, lower, digit, no triple)"
pw=$(value "$su" "#new")
for _ in {1..40}; do [ "$(op mock check localhost dana@example.com "$pw")" = true ] && break; sleep 0.1; done
[ "$(op mock check localhost dana@example.com "$pw")" = true ] || fail "the new login is not in 1Password with the filled password"
shot_page "$su" signup-filled
bench eval "$su" "document.getElementById('f').requestSubmit(); 'sent'" >/dev/null
sleep 2.5
[ "$(json "$(bench op offer)" "d['offer']")" = None ] || fail "a save offer for the password already kept: $(bench op offer)"
echo "PASS sign-up: 16-char password to the rules in both boxes, saved to 1Password before submit, no second offer"
bench close "$su" >/dev/null

# --- 3. UKG's change form, 1Password -----------------------------------------
ch=$(bench open "http://localhost:$port/change?u=alice@example.com")
wait_eval "$ch" "document.readyState === 'complete' && !!window.__officeForms" || fail "change page"
roles=$(bench eval "$ch" "['OldPass','Pass1','Pass2'].map(n => (window.__officeForms.classify(document.getElementById(n)) || {}).role).join(',')")
[ "$roles" = current,new,confirm ] || fail "roles $roles"
rows=$(rows_after_focus "$ch" "#Pass1")
[ "$(json "$rows" "d['rows'][0]")" = new-password ] || fail "change form list: $rows"
shot_list change-list
old_rows=$(rows_after_focus "$ch" "#OldPass")
json "$old_rows" "'new-password' not in d['rows'] and len(d['rows']) > 0" | grep -q True || fail "OldPass list: $old_rows"
rows_after_focus "$ch" "#Pass1" >/dev/null
bench op pick new-password >/dev/null
wait_eval "$ch" "(() => { const a = document.getElementById('Pass1').value;
  return a.length === 20 && a === document.getElementById('Pass2').value && /[^A-Za-z0-9]/.test(a); })()" \
  || fail "Pass1/Pass2 not filled"
wait_eval "$ch" "document.getElementById('OldPass').value === 'alice-localhost-pw'" || fail "OldPass not filled from the saved login"
pw=$(value "$ch" "#Pass1")
for _ in {1..40}; do [ "$(op mock check Localhost alice@example.com "$pw")" = true ] && break; sleep 0.1; done
[ "$(op mock check Localhost alice@example.com "$pw")" = true ] || fail "the 1Password item was not updated"
shot_page "$ch" change-filled
items=$(op mock show | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for i in d["items"] if i.get("user")=="alice@example.com"))')
[ "$items" = 1 ] || fail "a twin was made for alice ($items items)"
bench eval "$ch" "document.getElementById('f').requestSubmit(); 'sent'" >/dev/null
sleep 2.5
[ "$(json "$(bench op offer)" "d['offer']")" = None ] || fail "a save offer after the change: $(bench op offer)"
echo "PASS change (1Password): roles current/new/confirm from names alone, old password in OldPass, item updated in place, no offer"
bench close "$ch" >/dev/null

# --- 4. The same form, keychain: wait for the change to go through ----------
bench op backend keychain >/dev/null
printf 'url,username,password\nhttp://localhost:%s/,erin@example.com,erin-old-pw\n' "$port" >"$tmp/logins.csv"
bench passwords import "$tmp/logins.csv" >/dev/null
for _ in {1..40}; do [ "$(json "$(bench passwords status)" "(d.get('lastImport') or {}).get('kept', -1)")" = 1 ] && break; sleep 0.1; done
kc=$(bench open "http://localhost:$port/change?u=erin@example.com")
wait_eval "$kc" "document.readyState === 'complete' && !!window.__officeForms" || fail "change page (keychain)"
rows_after_focus "$kc" "#Pass1" >/dev/null
bench op pick new-password >/dev/null
wait_eval "$kc" "document.getElementById('Pass1').value.length === 20 && document.getElementById('OldPass').value === 'erin-old-pw'" \
  || fail "keychain change not filled"
pw=$(value "$kc" "#Pass1")
[ "$(json "$(bench passwords check localhost erin@example.com erin-old-pw)" "d['matches']")" = True ] || fail "keychain changed before submit"
bench eval "$kc" "document.getElementById('f').requestSubmit(); 'sent'" >/dev/null
offer='{}'
for _ in {1..50}; do
  offer=$(bench op offer)
  [ "$(json "$offer" "d['offer'] is not None")" = True ] && break
  sleep 0.1
done
[ "$(json "$offer" "(d['offer'] or {}).get('user')")" = erin@example.com ] || fail "no update offer for erin: $offer"
[ "$(json "$offer" "d['offer']['changed']")" = True ] || fail "offer is not an update: $offer"
bench op offer keep >/dev/null
for _ in {1..20}; do [ "$(json "$(bench passwords check localhost erin@example.com "$pw")" "d['matches']")" = True ] && break; sleep 0.1; done
[ "$(json "$(bench passwords check localhost erin@example.com "$pw")" "d['matches']")" = True ] || fail "keychain not updated after keep"
echo "PASS change (keychain): filled, keychain untouched until submit, Update offer for erin kept the new password"
bench close "$kc" >/dev/null

# --- 5. Typed by hand: sign-up, then a change that names no account ---------
typed() { # ID SELECTOR VALUE
  bench eval "$1" "(() => { const b = document.querySelector('$2'); b.focus(); b.value = '$3';
    b.dispatchEvent(new Event('input', {bubbles: true})); return 'typed'; })()" >/dev/null
}
wait_offer() {
  local offer='{}'
  for _ in {1..50}; do
    offer=$(bench op offer)
    [ "$(json "$offer" "d['offer'] is not None")" = True ] && break
    sleep 0.1
  done
  echo "$offer"
}
ts=$(bench open "http://localhost:$port/signup")
wait_eval "$ts" "document.readyState === 'complete' && !!window.__officeForms" || fail "signup page (typed)"
typed "$ts" "#email" frank@example.com
typed "$ts" "#new" Typed-by-hand-1
typed "$ts" "#again" Typed-by-hand-1
bench eval "$ts" "document.getElementById('f').requestSubmit(); 'sent'" >/dev/null
offer=$(wait_offer)
[ "$(json "$offer" "(d['offer'] or {}).get('user')")" = frank@example.com ] || fail "no save offer for frank: $offer"
[ "$(json "$offer" "d['offer']['changed']")" = False ] || fail "a new account reads as an update: $offer"
bench op offer keep >/dev/null
for _ in {1..20}; do [ "$(json "$(bench passwords check localhost frank@example.com Typed-by-hand-1)" "d['matches']")" = True ] && break; sleep 0.1; done
[ "$(json "$(bench passwords check localhost frank@example.com Typed-by-hand-1)" "d['matches']")" = True ] || fail "frank not saved"
bench close "$ts" >/dev/null
bench passwords forget localhost frank@example.com >/dev/null
echo "PASS typed sign-up: Save offer for frank with the new password"

tc=$(bench open "http://localhost:$port/change?then=login")
wait_eval "$tc" "document.readyState === 'complete' && !!window.__officeForms" || fail "change page (typed)"
typed "$tc" "#OldPass" whatever-it-was
typed "$tc" "#Pass1" Typed-change-22
typed "$tc" "#Pass2" Typed-change-22
bench eval "$tc" "document.getElementById('f').requestSubmit(); 'sent'" >/dev/null
offer=$(wait_offer)
[ "$(json "$offer" "(d['offer'] or {}).get('user')")" = erin@example.com ] || fail "no update offer for erin after a typed change: $offer"
[ "$(json "$offer" "d['offer']['changed']")" = True ] || fail "typed change is not an update: $offer"
bench op offer keep >/dev/null
for _ in {1..20}; do [ "$(json "$(bench passwords check localhost erin@example.com Typed-change-22)" "d['matches']")" = True ] && break; sleep 0.1; done
[ "$(json "$(bench passwords check localhost erin@example.com Typed-change-22)" "d['matches']")" = True ] || fail "erin not updated to the typed password"
echo "PASS typed change: the new box (not OldPass) offered as an Update for erin, though a sign-in form followed"
bench close "$tc" >/dev/null

# --- 6. Agents ---------------------------------------------------------------
copper() { SEARCH_PROBE="$world" SEARCH_MCP_PORT="$mcp_port" "$root/build/Copper.app/Contents/Resources/bin/copper" "$@"; }
bench op backend onepassword >/dev/null
ag=$(bench open "http://localhost:$port/change?u=alice@example.com")
wait_eval "$ag" "document.readyState === 'complete' && !!window.__officeForms" || fail "change page (agent)"
bench select "$ag" >/dev/null
out=$(copper call browser_autofill '{"kind":"new-password","reason":"e2e"}' 2>&1 || true)
case "$out" in *"not shared with agents"*) ;; *) fail "unshared login was not refused: $out";; esac
wait_eval "$ag" "document.getElementById('Pass1').value === '' && document.getElementById('OldPass').value === ''" 5 \
  || fail "a refused call filled something"
bench op share all on >/dev/null
out=$(copper call browser_autofill '{"kind":"new-password","reason":"e2e"}' 2>&1) || fail "agent call: $out"
pw=$(value "$ag" "#Pass1")
[ ${#pw} = 20 ] || fail "agent fill length ${#pw}"
case "$out" in *"$pw"*) fail "the password is in the agent's answer";; esac
python3 -c 'import json,re,sys; t=sys.argv[1]; d=json.loads(re.search(r"\{.*\}", t, re.S).group(0))
assert d["saved"] and d["updated"] and d["current"] and d["user"]=="alice@example.com" and d["length"]==20 and d["filled"]==2, d' "$out" \
  || fail "agent answer: $out"
[ "$(op mock check Localhost alice@example.com "$pw")" = true ] || fail "agent change not saved"
bench close "$ag" >/dev/null
echo "PASS agent change: refused while unshared; shared, saved + filled with no password in the answer"

as=$(bench open "http://localhost:$port/signup")
wait_eval "$as" "document.readyState === 'complete' && !!window.__officeForms" || fail "signup page (agent)"
bench select "$as" >/dev/null
out=$(copper autofill new-password --account gina@example.com --submit 2>&1) || fail "copper autofill new-password: $out"
wait_eval "$as" "!!document.getElementById('ok')" || fail "agent sign-up was not submitted: $out"
python3 - "$OP_MOCK_STATE" <<'PY' || fail "no 1Password login for gina"
import json, sys
items = json.load(open(sys.argv[1]))["items"]
sys.exit(0 if any(i.get("title") == "localhost" and i.get("additional_information") == "gina@example.com" for i in items) else 1)
PY
sleep 2.5
[ "$(json "$(bench op offer)" "d['offer']")" = None ] || fail "a save offer after the agent's sign-up: $(bench op offer)"
echo "PASS agent sign-up: copper autofill new-password --account --submit made gina's login, no offer"
echo "ALL PASS"
