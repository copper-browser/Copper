#!/bin/bash
# Bitwarden vault passkeys signed by Copper's authenticator, in real WebKit.
# A fresh headless probe world, a mock `bw` (docs/fixtures/bw-mock/bw) seeded
# with synthetic fido2Credentials for a localhost relying party, a file
# stand-in for the keychain, and a loopback MCP agent on its own port. No real
# vault, account, keychain item, Touch ID prompt or Copper profile.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="passkey-bw-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""; server=""
bench() { "$root/bench" --world "$world" "$@"; }
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  # cfprefsd leaves the emptied domain's file behind.
  rm -f "$HOME/Library/Preferences/com.officecommun.search.test.$world.plist"
  rm -rf "$folder" "$tmp"
  local hash=2166136261 i byte stem
  for ((i = 0; i < ${#world}; i++)); do
    printf -v byte '%d' "'${world:i:1}"
    hash=$(( ((hash ^ byte) * 16777619) & 0xFFFFFFFF ))
  done
  stem=$(printf '5E4C%04X-%04X' $((hash >> 16)) $((hash & 0xFFFF)))
  local kit="$HOME/Library/WebKit/com.collinrijock.copper.dev"
  rm -rf "$kit/WebExtensions/$stem-"* "$kit/WebsiteDataStore/$(tr 'A-F' 'a-f' <<<"$stem")-"*
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { echo "FAIL $*"; exit 1; }
ok() { echo "ok   $*"; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && swift build -c release --jobs 4 && SEARCH_SIGN_IDENTITY=- ./build.sh)
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"

# Synthetic P-256 keys: PKCS#8 for the vault (base64url, as Bitwarden
# writes it — B in plain base64, which Copper also reads), SPKI for WebCrypto.
for k in a b c d e f g; do
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/$k.pem" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$tmp/$k.pem" -outform DER 2>/dev/null | base64 | tr -d '\n' >"$tmp/$k.pkcs8"
  openssl ec -in "$tmp/$k.pem" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n' >"$tmp/$k.spki"
done

# Two ports: the page, and a second localhost origin whose /frame page asks
# for a passkey from inside an iframe (same site, another origin) and posts
# the outcome to its parent.
python3 - "$tmp/port" "$tmp/port2" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, json, pathlib, sys, threading, urllib.parse
FRAME = """<!doctype html><meta charset="utf-8"><script>
navigator.credentials.get({publicKey: {challenge: new Uint8Array([3]), rpId: 'localhost', userVerification: 'preferred'}})
  .then(function (c) { parent.postMessage({frame: NAME, ok: true, id: c.id}, '*'); },
        function (e) { parent.postMessage({frame: NAME, error: e.name, message: e.message}, '*'); });
</script>"""
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == '/frame':
            name = urllib.parse.parse_qs(url.query).get('n', ['frame'])[0]
            data = FRAME.replace('NAME', json.dumps(name)).encode()
        else:
            data=b'<!doctype html><meta charset="utf-8"><title>Synthetic Bitwarden passkey check</title><p>No real credentials.</p>'
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass
servers=[http.server.ThreadingHTTPServer(('127.0.0.1',0),Page) for _ in range(2)]
threading.Thread(target=servers[1].serve_forever, daemon=True).start()
pathlib.Path(sys.argv[2]).write_text(str(servers[1].server_port))
pathlib.Path(sys.argv[1]).write_text(str(servers[0].server_port))
servers[0].serve_forever()
PY
server=$!
for _ in {1..40}; do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] && [ -s "$tmp/port2" ] || fail "localhost server"
port=$(<"$tmp/port"); port2=$(<"$tmp/port2")
mcp_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

# The vault: alice (discoverable, in the Agents folder, counter 0), bob
# (discoverable, b64.-style id, counter 5, not shared), carol (not
# discoverable), dave's on another relying party, frank's login with a
# password and no passkey, kim (counter at UInt32.max), lena (Agents folder
# but master-password reprompt on), ivan's login holding an EdDSA passkey
# Copper cannot sign with (so the cache leaves it out), and judy's
# password-only login owned by an organization.
mkdir -p "$tmp/bw"
python3 - "$tmp" "$port" <<'PY'
import base64, json, pathlib, sys
tmp, port = pathlib.Path(sys.argv[1]), sys.argv[2]
key = lambda k: (tmp / f"{k}.pkcs8").read_text().strip()
url = lambda k: base64.urlsafe_b64encode(base64.b64decode(key(k))).decode().rstrip("=")
def passkey(cid, kv, rp, user, handle, counter, discoverable):
    return {"credentialId": cid, "keyType": "public-key", "keyAlgorithm": "ECDSA", "keyCurve": "P-256",
            "keyValue": kv, "rpId": rp, "userHandle": base64.urlsafe_b64encode(handle).decode().rstrip("="),
            "userName": user, "counter": counter, "rpName": "Synthetic", "userDisplayName": user.title(),
            "discoverable": discoverable, "creationDate": "2026-09-01T12:00:00.000Z"}
def item(iid, user, folder, pk, rp="localhost", reprompt=0):
    return {"object": "item", "id": iid, "type": 1, "name": f"{rp} ({user})", "folderId": folder,
            "notes": None, "favorite": False, "fields": [], "reprompt": reprompt,
            "login": {"username": user, "password": "synthetic-not-a-password", "totp": None,
                      "uris": [{"uri": f"http://{rp}:{port}" if rp == "localhost" else f"https://{rp}", "match": None}],
                      "fido2Credentials": [pk]}}
bob_id = base64.urlsafe_b64encode(b"bob-credential-id-0001").decode().rstrip("=")
ids = {"a": "6f1b3a52-1c0e-4a37-9c55-2d1f0e9a7b01", "b": "b64." + bob_id,
       "c": "0c9d2e11-5b7a-4f3e-8d21-7a6b5c4d3e02", "d": "d4e5f6a7-0b1c-4d2e-9f30-415263748596",
       "e": "e1e2e3e4-0b1c-4d2e-9f30-415263748597", "f": "f1f2f3f4-0b1c-4d2e-9f30-415263748598",
       "g": "a7a7a7a7-0b1c-4d2e-9f30-415263748599"}
items = [
    item("item-alice", "alice", "folder-agents", passkey(ids["a"], url("a"), "localhost", "alice", b"alice-handle", "0", "true")),
    item("item-bob", "bob", None, passkey(ids["b"], key("b"), "localhost", "bob", b"bob-handle", "5", "true")),
    item("item-carol", "carol", None, passkey(ids["c"], url("c"), "localhost", "carol", b"carol-handle", "0", "false")),
    item("item-dave", "dave", None, passkey(ids["d"], url("d"), "example.test", "dave", b"dave-handle", "0", "true"), rp="example.test"),
]
# frank: a password-only login on the site, which a new passkey joins.
frank = item("item-frank", "frank", None, None)
frank["login"]["fido2Credentials"] = []
items.append(frank)
items.append(item("item-kim", "kim", None, passkey(ids["e"], url("e"), "localhost", "kim", b"kim-handle", "4294967295", "false")))
items.append(item("item-lena", "lena", "folder-agents", passkey(ids["f"], url("f"), "localhost", "lena", b"lena-handle", "0", "true"), reprompt=1))
ivan_pk = passkey(ids["g"], url("g"), "localhost", "ivan", b"ivan-handle", "0", "true")
ivan_pk["keyAlgorithm"], ivan_pk["keyCurve"] = "EdDSA", "Ed25519"
items.append(item("item-ivan", "ivan", None, ivan_pk))
judy = item("item-judy", "judy", None, None)
judy["login"]["fido2Credentials"] = None
judy["organizationId"], judy["collectionIds"] = "org-synthetic", ["collection-synthetic"]
items.append(judy)
state = {"password": "synthetic-master", "status": "locked", "email": "probe@example.invalid",
         "folders": [{"object": "folder", "id": "folder-agents", "name": "Agents"}], "items": items}
(tmp / "bw" / "state.json").write_text(json.dumps(state, indent=1))
# The raw credential ids as a site sees them, base64url.
import uuid
raw = {k: (uuid.UUID(v).bytes if not v.startswith("b64.") else base64.urlsafe_b64decode(v[4:] + "==")) for k, v in ids.items()}
(tmp / "ids.json").write_text(json.dumps({k: base64.urlsafe_b64encode(v).decode().rstrip("=") for k, v in raw.items()}))
PY

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
defaults write "com.officecommun.search.test.$world" probe.keychain -string file
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_BW_PATH="$root/docs/fixtures/bw-mock/bw" \
  BW_MOCK_STATE="$tmp/bw/state.json" SEARCH_MCP_PORT="$mcp_port" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null || fail "headless bench"

bench bw unlock synthetic-master >/dev/null
for _ in {1..80}; do
  bench passkeys count >"$tmp/count.json" 2>/dev/null || true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["bitwarden"]==6' "$tmp/count.json" 2>/dev/null && break
  sleep 0.25
done
python3 - "$tmp/count.json" <<'PY' || fail "vault passkeys not listed: $(cat "$tmp/count.json")"
import json,sys
d=json.load(open(sys.argv[1])); assert d["count"]==0 and d["bitwarden"]==6, d
PY
bench passkeys list >"$tmp/list.json"
python3 - "$tmp/list.json" <<'PY'
import json,sys
rows=[r for r in json.load(open(sys.argv[1]))["credentials"] if r["source"]=="bitwarden"]
by={r["userName"]: r for r in rows}
assert set(by)=={"alice","bob","carol","dave","kim","lena"}, rows
assert by["alice"]["agent"] is True and by["bob"]["agent"] is False, rows
assert by["lena"]["agent"] is False, "a reprompt login's passkey must not be an agent's"
assert by["carol"]["discoverable"] is False and by["bob"]["counter"]==5, rows
assert all("key" not in k.lower() for r in rows for k in r), rows
PY
ok "Settings/bench list: six vault passkeys (the EdDSA one left out), source Bitwarden, metadata only; reprompt lena not an agent's"
bench bw candidates localhost >"$tmp/candidates.json"
python3 -c 'import json,sys; c={x["user"]: x for x in json.load(open(sys.argv[1]))["candidates"] if x["source"]=="bitwarden"}; assert c["alice"]["passkey"] and c["carol"]["passkey"] and not c["frank"]["passkey"], c' "$tmp/candidates.json" \
  || fail "picker rows do not say passkey: $(cat "$tmp/candidates.json")"
ok "password picker rows mark logins that hold a passkey"

id=$(bench open "http://localhost:$port/")
loaded=0
for _ in {1..40}; do
  ready=$(bench eval "$id" "({ready: document.readyState === 'complete', bridge: !!window.__copperPasskeys})")
  if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ready"] and d["bridge"]' "$ready" 2>/dev/null; then loaded=1; break; fi
  sleep 0.1
done
[ "$loaded" = 1 ] || fail "page/bridge not ready: $ready"

# One helper in the page: run get() (or create() then get()), verify the ES256
# signature over authData || SHA-256(clientDataJSON) against the given SPKI.
lib=$(cat <<'JS'
window.__pk = {};
window.__bytes = function (s) { s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
  var r = atob(s), o = new Uint8Array(r.length); for (var i = 0; i < r.length; i++) o[i] = r.charCodeAt(i); return o; };
window.__b64u = function (b) { var a = new Uint8Array(b), s = ''; for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
window.__verify = async function (got, spki) {
  var der = new Uint8Array(got.response.signature), raw = new Uint8Array(64), offset = 2;
  if (der[0] !== 0x30) throw new Error('Invalid DER');
  for (var c = 0; c < 2; c++) {
    if (der[offset++] !== 0x02) throw new Error('Invalid DER integer');
    var n = der[offset++], v = der.slice(offset, offset + n); offset += n;
    while (v.length > 32 && v[0] === 0) v = v.slice(1);
    raw.set(v, c * 32 + 32 - v.length);
  }
  var key = await crypto.subtle.importKey('spki', spki, {name: 'ECDSA', namedCurve: 'P-256'}, false, ['verify']);
  var auth = new Uint8Array(got.response.authenticatorData);
  var hash = new Uint8Array(await crypto.subtle.digest('SHA-256', got.response.clientDataJSON));
  var signed = new Uint8Array(auth.length + hash.length); signed.set(auth); signed.set(hash, auth.length);
  var rp = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('localhost')));
  var client = JSON.parse(new TextDecoder().decode(got.response.clientDataJSON));
  return {verified: await crypto.subtle.verify({name: 'ECDSA', hash: 'SHA-256'}, key, raw, signed),
          rpHash: rp.every(function (x, i) { return x === auth[i]; }), uv: !!(auth[32] & 4), up: !!(auth[32] & 1),
          counter: (auth[33] << 24 | auth[34] << 16 | auth[35] << 8 | auth[36]) >>> 0,
          type: client.type, origin: client.origin,
          id: got.id, user: got.response.userHandle ? new TextDecoder().decode(got.response.userHandle) : null};
};
window.__frame = function (name, port) {
  window.__pk[name] = {running: true};
  if (!window.__frames) {
    window.__frames = true;
    window.addEventListener('message', function (e) {
      if (e.data && e.data.frame) window.__pk[e.data.frame] = Object.assign({running: false}, e.data);
    });
  }
  var f = document.createElement('iframe');
  f.src = 'http://localhost:' + port + '/frame?n=' + encodeURIComponent(name);
  document.body.appendChild(f);
  return 'started';
};
window.__get = function (name, allow, spki, uv) {
  window.__pk[name] = {running: true};
  (async function () {
    try {
      var got = await navigator.credentials.get({publicKey: {challenge: crypto.getRandomValues(new Uint8Array(16)), rpId: 'localhost',
        userVerification: uv || 'required', allowCredentials: allow.map(function (id) { return {type: 'public-key', id: window.__bytes(id)}; })}});
      var spkis = typeof spki === 'string' ? {only: spki} : spki, out = {running: false};
      for (var k in spkis) { var r = await window.__verify(got, window.__bytes(spkis[k])); if (r.verified || !out.id) { out = Object.assign({running: false, key: k}, r); } }
      window.__pk[name] = out;
    } catch (e) { window.__pk[name] = {running: false, error: e.name, message: e.message}; }
  })();
  return 'started';
};
window.__create = function (name, user) {
  window.__pk[name] = {running: true};
  (async function () {
    try {
      var made = await navigator.credentials.create({publicKey: {challenge: new Uint8Array([9, 9]),
        rp: {id: 'localhost', name: 'Synthetic RP'}, user: {id: new TextEncoder().encode(user + '-handle'), name: user, displayName: user},
        pubKeyCredParams: [{type: 'public-key', alg: -7}], authenticatorSelection: {residentKey: 'required', userVerification: 'required'}}});
      var got = await navigator.credentials.get({publicKey: {challenge: new Uint8Array([7]), rpId: 'localhost',
        allowCredentials: [{type: 'public-key', id: made.rawId}]}});
      var r = await window.__verify(got, made.response.getPublicKey());
      window.__pk[name] = Object.assign({running: false, made: made.id}, r);
    } catch (e) { window.__pk[name] = {running: false, error: e.name, message: e.message}; }
  })();
  return 'started';
};
'ready';
JS
)
bench eval "$id" "$lib" >/dev/null
ids_json=$(<"$tmp/ids.json")
spki() { tr '+/' '-_' <"$tmp/$1.spki" | tr -d '='; }
keys_json="{\"alice\":\"$(spki a)\",\"bob\":\"$(spki b)\",\"carol\":\"$(spki c)\",\"kim\":\"$(spki e)\"}"
idof() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$ids_json" "$1"; }
wait_result() { # tab name file
  for _ in {1..150}; do
    bench eval "$1" "window.__pk['$2']" >"$3"
    if python3 -c 'import json,sys; assert not json.load(open(sys.argv[1]))["running"]' "$3" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  fail "$2 timed out: $(cat "$3")"
}
gets() { grep -c '"argv": \["get", "item"' "$tmp/bw/calls.log" || true; }

bench passkeys answer yes >/dev/null
bench passkeys pick ask >/dev/null

# 1. allowCredentials naming a non-discoverable vault passkey.
bench eval "$id" "window.__get('carol', ['$(idof c)'], $keys_json)" >/dev/null
wait_result "$id" carol "$tmp/carol.json"
python3 - "$tmp/carol.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert not r.get("error"), r
assert r["key"]=="carol" and r["verified"] and r["rpHash"] and r["uv"] and r["up"], r
assert r["user"]=="carol-handle" and r["counter"]==0 and r["type"]=="webauthn.get", r
PY
ok "allowCredentials → carol's non-discoverable vault passkey; ES256 verified with WebCrypto; UV+UP, RP hash"

# 2. No allowCredentials: only discoverable ones are offered; the chooser
#    picks bob, whose non-zero counter advances in the vault.
bench passkeys pick bob >/dev/null
bench eval "$id" "window.__get('bob', [], $keys_json)" >/dev/null
wait_result "$id" bob "$tmp/bob.json"
bench passkeys offered >"$tmp/offered.json"
python3 - "$tmp/bob.json" "$tmp/offered.json" "$tmp/bw/state.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); offered=json.load(open(sys.argv[2]))["offered"]
state=json.load(open(sys.argv[3]))
assert not r.get("error"), r
assert r["key"]=="bob" and r["verified"] and r["uv"] and r["counter"]==6 and r["user"]=="bob-handle", r
assert sorted(offered)==["alice · Bitwarden","bob · Bitwarden","lena · Bitwarden"], offered
counters={i["id"]: i["login"]["fido2Credentials"][0]["counter"] for i in state["items"] if i["login"]["fido2Credentials"]}
assert counters["item-bob"]=="6" and counters["item-alice"]=="0", counters
PY
grep -q '"argv": \["edit", "item", "item-bob"\], "env": \[[^]]*\], "stdin": [1-9]' "$tmp/bw/calls.log" || fail "counter edit did not go on stdin"
ok "discoverable selection: chooser offered alice+bob+lena (not carol/kim), picked bob; counter 5→6 in authData and the vault (edit on stdin)"

# 3. alice by id: counter 0 stays 0, and the vault item is not edited.
bench eval "$id" "window.__get('alice', ['$(idof a)'], $keys_json)" >/dev/null
wait_result "$id" alice "$tmp/alice.json"
python3 - "$tmp/alice.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert not r.get("error") and r["key"]=="alice" and r["verified"] and r["counter"]==0, r
PY
grep -q '"edit", "item", "item-alice"' "$tmp/bw/calls.log" && fail "a zero counter was written back"
ok "zero counter stays zero and is not written back"

# 4. User verification refused: no assertion, and the key is never read.
before=$(gets)
bench passkeys answer no >/dev/null
bench eval "$id" "window.__get('refused', ['$(idof a)'], $keys_json)" >/dev/null
wait_result "$id" refused "$tmp/refused.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError", r' "$tmp/refused.json" || fail "UV refusal: $(cat "$tmp/refused.json")"
[ "$(gets)" = "$before" ] || fail "the vault key was read before user verification"
bench passkeys answer yes >/dev/null
ok "UV required: Touch ID refused → NotAllowedError, no 'bw get item'"

# 5. A passkey for another relying party never matches.
bench eval "$id" "window.__get('other', ['$(idof d)'], $keys_json)" >/dev/null
wait_result "$id" other "$tmp/other.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError", r' "$tmp/other.json" || fail "other RP: $(cat "$tmp/other.json")"
ok "another RP's vault passkey is never offered"

# 6. An agent in its own background tab, over MCP: the chooser and Touch ID
#    are set to answer bob / no, so a pass proves neither was consulted.
token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$folder/agent.json")
mcp() { # json-body → reply on stdout; every reply is kept in mcp-all.log
  curl -s --max-time 30 -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $sid" "http://127.0.0.1:$mcp_port/mcp" -d "$1" \
    | tee -a "$tmp/mcp-all.log"
  echo >>"$tmp/mcp-all.log"
}
# Whether an agent's tool result carried this passkey refusal reason.
told() { grep -q "Passkey sign-in refused on this tab: [^\"]*$1" "$tmp/mcp-all.log"; }
# The standard WebAuthn wording, all a page may learn from a refusal.
standard="The operation either timed out or was not allowed"
sid=""
for _ in {1..40}; do
  sid=$(curl -s -D - -o /dev/null --max-time 5 -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "http://127.0.0.1:$mcp_port/mcp" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"passkey-bw-e2e"}}}' \
    | awk 'tolower($1)=="mcp-session-id:" {print $2}' | tr -d '\r') || true
  [ -n "$sid" ] && break; sleep 0.25
done
[ -n "$sid" ] || fail "MCP initialize"
call() { python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$1" "$2"; }
# Built outside $(…): /bin/bash 3.2 brace-expands a literal {…,…} there.
new_tab="{\"action\":\"new\",\"url\":\"http://localhost:$port/\"}"
mcp "$(call browser_tabs "$new_tab")" >"$tmp/mcp-new.json"
# The page value inside a browser_evaluate reply (a JSON string the page made).
inner() { python3 - "$1" <<'PY'
import json,sys
text=json.load(open(sys.argv[1]))["result"]["content"][0]["text"]
while isinstance(text, str):
    try: text=json.loads(text)
    except ValueError: break
print(json.dumps(text))
PY
}
settled() { inner "$1" 2>/dev/null | python3 -c 'import json,sys; assert json.load(sys.stdin)["running"] is False' 2>/dev/null; }
evaluate() { mcp "$(call browser_evaluate "$(python3 -c 'import json,sys; print(json.dumps({"function": sys.argv[1]}))' "$1")")"; }
for _ in {1..40}; do
  evaluate "() => String(document.readyState === 'complete' && !!window.__copperPasskeys)" >"$tmp/mcp-ready.json"
  [ "$(inner "$tmp/mcp-ready.json" 2>/dev/null)" = true ] && break; sleep 0.15
done
[ "$(inner "$tmp/mcp-ready.json" 2>/dev/null)" = true ] || fail "agent tab not ready: $(cat "$tmp/mcp-ready.json")"
bench passkeys answer no >/dev/null
bench passkeys pick bob >/dev/null
agent_wait() { # name → the page's result in $tmp/<name>.json
  for _ in {1..150}; do
    evaluate "() => JSON.stringify(window.__pk['$1'])" >"$tmp/mcp-$1.json"
    settled "$tmp/mcp-$1.json" && break; sleep 0.1
  done
  inner "$tmp/mcp-$1.json" >"$tmp/$1.json"
}
# Discoverable, UV preferred: lena is in the Agents folder too, but her
# login has Bitwarden's reprompt on, so alice is the one shared passkey.
evaluate "() => { $(tr '\n' ' ' <<<"$lib") return window.__get('agent', [], $keys_json, 'preferred'); }" >"$tmp/mcp-start.json"
agent_wait agent
evaluate "() => { window.__get('agent-bob', ['$(idof b)'], $keys_json, 'preferred'); return 'started'; }" >/dev/null
agent_wait agent-bob
python3 - "$tmp/agent.json" "$tmp/agent-bob.json" "$standard" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert not a.get("error") and a["key"]=="alice" and a["verified"], a
assert a["up"] and not a["uv"], ("an agent's assertion claims presence only", a)
assert b.get("error")=="NotAllowedError" and b["message"].startswith(sys.argv[3]), b
assert "shared" not in b["message"] and "bob" not in b["message"] and "Bitwarden" not in b["message"], b
PY
told "a Bitwarden passkey for localhost exists but is not shared with agents" || fail "the agent was not told why bob was refused"
ok "agent tab: shared alice signs with no chooser/Touch ID, UP without UV; reprompt lena not used; unshared bob → bare NotAllowedError on the page, the Agent access hint in the agent's next result"

# userVerification required: nobody can verify for an agent → refused.
before=$(gets)
evaluate "() => { window.__get('agent-uv', ['$(idof a)'], $keys_json, 'required'); return 'started'; }" >/dev/null
agent_wait agent-uv
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError" and r["message"].startswith(sys.argv[2]), r' "$tmp/agent-uv.json" "$standard" \
  || fail "agent with UV required: $(cat "$tmp/agent-uv.json")"
told "requires user verification" || fail "the agent was not told UV is required"
[ "$(gets)" = "$before" ] || fail "the vault key was read for a UV-required agent request"
# A frame of another origin in the agent's tab is not the agent's page.
evaluate "() => window.__frame('agent-frame', $port2)" >/dev/null
agent_wait agent-frame
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError" and r["message"].startswith(sys.argv[2]), r' "$tmp/agent-frame.json" "$standard" \
  || fail "agent tab, cross-origin frame: $(cat "$tmp/agent-frame.json")"
told "in a frame" || fail "the agent was not told the frame was refused"
[ "$(gets)" = "$before" ] || fail "the vault key was read for a frame's request"
bench passkeys answer yes >/dev/null
ok "agent tab: UV required → refused (no key read); a cross-origin iframe's request → refused; reasons reach the agent only"

# 6b. browser_sign_in what=passkey arms one sign-in; it reads no key itself.
signin() { # json-args → the tool's text (or the error text) on stdout
  mcp "$(call browser_sign_in "$1")" >"$tmp/mcp-signin.json"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["content"][0]["text"])' "$tmp/mcp-signin.json"
}
before=$(gets)
bob_args='{"what":"passkey","account":"bob"}'
signin "$bob_args" >"$tmp/signin-bob.txt"
grep -q "not shared with agents" "$tmp/signin-bob.txt" || fail "arming an unshared passkey: $(cat "$tmp/signin-bob.txt")"
signin '{"what":"passkey"}' >"$tmp/signin-alice.txt"
python3 - "$tmp/signin-alice.txt" <<'PY2'
import json,sys
r=json.loads(open(sys.argv[1]).read())
assert r.get("armed") is True and r["account"]=="alice" and r["what"]=="passkey" and r["source"]=="bitwarden", r
assert not any("key" in k.lower() for k in r), r
PY2
[ "$(gets)" = "$before" ] || fail "arming read the vault item"
ok "browser_sign_in what=passkey: unshared bob refused (Agent access hint); alice armed, result has no key, no vault read"

# 6c. The person's tab, on screen, which the agent now holds: a request there
#     is still the person's (Touch ID says no → refused) until the agent arms
#     it; armed, it signs once with no prompt; the next is the person's again.
bench eval "$id" "window.__mark = 'person'" >/dev/null
# focus: the person's window shows it, so it is on screen.
select_tab="{\"action\":\"select\",\"tab\":\"$id\",\"focus\":true}"
mcp "$(call browser_tabs "$select_tab")" >"$tmp/mcp-select.json"
evaluate "() => String(window.__mark)" >"$tmp/mcp-mark.json"
[ "$(inner "$tmp/mcp-mark.json")" = '"person"' ] || fail "agent did not bind the person's tab: $(cat "$tmp/mcp-mark.json")"
bench passkeys answer no >/dev/null
bench eval "$id" "window.__get('held', ['$(idof a)'], $keys_json)" >/dev/null
wait_result "$id" held "$tmp/held.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError", r' "$tmp/held.json" \
  || fail "a held, on-screen tab signed without the person: $(cat "$tmp/held.json")"
signin '{"what":"passkey","account":"alice"}' >"$tmp/signin-armed.txt"
grep -q '"armed":true' "$tmp/signin-armed.txt" || fail "arm the person's tab: $(cat "$tmp/signin-armed.txt")"
# Armed for this page: a frame of another origin inside it does not get the
# grant (it is the person's request, and Touch ID says no), nor use it up.
bench eval "$id" "window.__frame('armed-frame', $port2)" >/dev/null
wait_result "$id" armed-frame "$tmp/armed-frame.json"
bench eval "$id" "window.__get('armed', [], $keys_json, 'preferred')" >/dev/null
wait_result "$id" armed "$tmp/armed.json"
bench eval "$id" "window.__get('rearmed', ['$(idof a)'], $keys_json, 'preferred')" >/dev/null
wait_result "$id" rearmed "$tmp/rearmed.json"
python3 - "$tmp/armed-frame.json" "$tmp/armed.json" "$tmp/rearmed.json" <<'PY2'
import json,sys
f=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); b=json.load(open(sys.argv[3]))
assert f.get("error")=="NotAllowedError", ("a frame used the page's grant", f)
assert not a.get("error") and a["key"]=="alice" and a["verified"] and a["up"] and not a["uv"] and a["user"]=="alice-handle", a
assert b.get("error")=="NotAllowedError", b
PY2
# Armed, but the site requires UV: the person decides (Touch ID says no),
# and the agent is told why.
signin '{"what":"passkey","account":"alice"}' >"$tmp/signin-armed-uv.txt"
grep -q '"armed":true' "$tmp/signin-armed-uv.txt" || fail "re-arm: $(cat "$tmp/signin-armed-uv.txt")"
bench eval "$id" "window.__get('armed-uv', ['$(idof a)'], $keys_json, 'required')" >/dev/null
wait_result "$id" armed-uv "$tmp/armed-uv.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError", r' "$tmp/armed-uv.json" || fail "armed + UV required signed: $(cat "$tmp/armed-uv.json")"
evaluate "() => 'after'" >/dev/null
told "requires user verification.*asked the person" || fail "the agent was not told the armed request went to the person"
bench passkeys answer yes >/dev/null
ok "on-screen tab an agent holds: person's Touch ID still decides; armed → a cross-origin frame neither gets nor spends the grant, the page's own request signs once (UP, no UV), then the person's again; armed + UV required → the person's"

# 7. Save new passkeys to Bitwarden: a passkey made here lands in the vault,
#    not the keychain stand-in, and signs straight away from there.
bench bw backend bitwarden >/dev/null
bench passkeys pick ask >/dev/null
bench eval "$id" "window.__create('erin', 'erin')" >/dev/null
wait_result "$id" erin "$tmp/erin.json"
python3 - "$tmp/erin.json" "$tmp/bw/state.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); state=json.load(open(sys.argv[2]))
assert not r.get("error") and r["verified"] and r["uv"] and r["user"]=="erin-handle", r
made=[i for i in state["items"] if i["login"]["username"]=="erin"]
assert len(made)==1, made
pk=made[0]["login"]["fido2Credentials"][0]
assert pk["rpId"]=="localhost" and pk["keyAlgorithm"]=="ECDSA" and pk["keyCurve"]=="P-256" and pk["discoverable"]=="true", pk
assert pk["counter"]=="0" and pk["userName"]=="erin" and pk["rpName"]=="Synthetic RP" and len(pk["keyValue"])>100, {k: v for k, v in pk.items() if k!="keyValue"}
import uuid
assert uuid.UUID(pk["credentialId"]).version==4 and str(uuid.UUID(pk["credentialId"]))==pk["credentialId"], pk["credentialId"]
PY
bench passkeys count >"$tmp/count2.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["count"]==0 and d["bitwarden"]==7, d' "$tmp/count2.json" || fail "count after create: $(cat "$tmp/count2.json")"
grep -q '"argv": \["create", "item"\], "env": \[[^]]*\], "stdin": [1-9]' "$tmp/bw/calls.log" || fail "create did not go on stdin"
ok "create with Bitwarden as the save target: new vault login with an ES256 fido2Credential (stdin, a v4 GUID id), none in the keychain; get() signs with it"

# 7b. A new passkey for an account the site's login already names joins that
#     login (Bitwarden keeps one passkey per login) instead of a second item.
bench eval "$id" "window.__create('frank', 'frank')" >/dev/null
wait_result "$id" frank "$tmp/frank.json"
python3 - "$tmp/frank.json" "$tmp/bw/state.json" <<'PY2'
import json,sys
r=json.load(open(sys.argv[1])); state=json.load(open(sys.argv[2]))
assert not r.get("error") and r["verified"] and r["user"]=="frank-handle", r
mine=[i for i in state["items"] if i["login"]["username"]=="frank"]
assert len(mine)==1 and mine[0]["id"]=="item-frank", [i["id"] for i in mine]
pks=mine[0]["login"]["fido2Credentials"]
assert len(pks)==1 and pks[0]["userName"]=="frank" and mine[0]["login"]["password"]=="synthetic-not-a-password", mine[0]["login"].keys()
PY2
grep -q '"argv": \["edit", "item", "item-frank"\], "env": \[[^]]*\], "stdin": [1-9]' "$tmp/bw/calls.log" || fail "join did not edit on stdin"
ok "a new passkey joins the site's password-only login for the same account (edit on stdin), password kept"

# 7d. ivan's login already holds a passkey the cache leaves out (EdDSA): a
#     new one must not replace it — it becomes a login of its own.
bench eval "$id" "window.__create('ivan', 'ivan')" >/dev/null
wait_result "$id" ivan "$tmp/ivan.json"
# 7e. judy's login belongs to an organization: joining would share the new
#     key with its collection, so it is a new personal login instead.
bench eval "$id" "window.__create('judy', 'judy')" >/dev/null
wait_result "$id" judy "$tmp/judy.json"
python3 - "$tmp/ivan.json" "$tmp/judy.json" "$tmp/bw/state.json" <<'PY2'
import json,sys
ivan=json.load(open(sys.argv[1])); judy=json.load(open(sys.argv[2])); state=json.load(open(sys.argv[3]))
assert not ivan.get("error") and ivan["verified"] and not judy.get("error") and judy["verified"], (ivan, judy)
by={}
for i in state["items"]: by.setdefault(i["login"]["username"], []).append(i)
old=[i for i in by["ivan"] if i["id"]=="item-ivan"][0]
assert [p["keyAlgorithm"] for p in old["login"]["fido2Credentials"]]==["EdDSA"], "ivan's existing passkey was replaced"
assert len(by["ivan"])==2, [i["id"] for i in by["ivan"]]
org=[i for i in by["judy"] if i["id"]=="item-judy"][0]
assert not org["login"]["fido2Credentials"], "a new passkey was added to an organization's login"
mine=[i for i in by["judy"] if i["id"]!="item-judy"]
assert len(mine)==1 and mine[0]["organizationId"] is None and mine[0]["login"]["fido2Credentials"][0]["userName"]=="judy", mine
PY2
grep -q '"edit", "item", "item-ivan"' "$tmp/bw/calls.log" && fail "ivan's login was edited"
grep -q '"edit", "item", "item-judy"' "$tmp/bw/calls.log" && fail "judy's organization login was edited"
ok "save: a login whose fresh copy has any passkey, or an organization's login, is never joined — a new personal login instead"

# 7f. A create that lands but reports a failure (a timed-out CLI call):
#     Copper finds it in the vault and keeps no second copy in the keychain.
python3 - "$tmp/bw/state.json" <<'PY2'
import fcntl, json, sys
lock=open(sys.argv[1] + ".lock", "w"); fcntl.flock(lock, fcntl.LOCK_EX)
state=json.load(open(sys.argv[1])); state["fail_after_create"]=True
json.dump(state, open(sys.argv[1], "w"), indent=1)
PY2
bench eval "$id" "window.__create('hana', 'hana')" >/dev/null
wait_result "$id" hana "$tmp/hana.json"
bench passkeys count >"$tmp/count-hana.json"
python3 - "$tmp/hana.json" "$tmp/count-hana.json" "$tmp/bw/state.json" <<'PY2'
import json,sys
r=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); state=json.load(open(sys.argv[3]))
assert not r.get("error") and r["verified"], r
assert "fail_after_create" not in state, "the fault was not exercised"
assert len([i for i in state["items"] if i["login"]["username"]=="hana"])==1
assert c["count"]==0, ("a duplicate went to the keychain", c)
PY2
grep -q 'holds the new passkey; not kept twice' "$tmp/copper.log" || fail "no log line for the landed create"
ok "create that landed but reported a timeout: one vault copy, none in the keychain"

# 7g. Counters: two sign-ins on one item at once get distinct counters; one
#     at UInt32.max stays there (no wrap to 0) and is not rewritten; a write
#     that loses the passkey stops further writes to that item.
bench eval "$id" "window.__get('bob-1', ['$(idof b)'], $keys_json); window.__get('bob-2', ['$(idof b)'], $keys_json)" >/dev/null
wait_result "$id" bob-1 "$tmp/bob-1.json"; wait_result "$id" bob-2 "$tmp/bob-2.json"
bench eval "$id" "window.__get('kim', ['$(idof e)'], $keys_json)" >/dev/null
wait_result "$id" kim "$tmp/kim.json"
python3 - "$tmp/bob-1.json" "$tmp/bob-2.json" "$tmp/kim.json" "$tmp/bw/state.json" <<'PY2'
import json,sys
b1, b2, kim = (json.load(open(p)) for p in sys.argv[1:4]); state=json.load(open(sys.argv[4]))
assert b1["verified"] and b2["verified"], (b1, b2)
assert sorted([b1["counter"], b2["counter"]])==[7, 8], (b1["counter"], b2["counter"])
by={i["id"]: i for i in state["items"]}
assert by["item-bob"]["login"]["fido2Credentials"][0]["counter"]=="8", by["item-bob"]["login"]["fido2Credentials"][0]["counter"]
assert kim["verified"] and kim["counter"]==4294967295, kim
assert by["item-kim"]["login"]["fido2Credentials"][0]["counter"]=="4294967295"
PY2
grep -q '"edit", "item", "item-kim"' "$tmp/bw/calls.log" && fail "a saturated counter was rewritten"
python3 - "$tmp/bw/state.json" <<'PY2'
import fcntl, json, sys
lock=open(sys.argv[1] + ".lock", "w"); fcntl.flock(lock, fcntl.LOCK_EX)
state=json.load(open(sys.argv[1])); state["hide_after_edit"]=["item-bob"]
json.dump(state, open(sys.argv[1], "w"), indent=1)
PY2
bench eval "$id" "window.__get('bob-3', ['$(idof b)'], $keys_json)" >/dev/null
wait_result "$id" bob-3 "$tmp/bob-3.json"
edits=$(grep -c '"edit", "item", "item-bob"' "$tmp/bw/calls.log")
bench eval "$id" "window.__get('bob-4', ['$(idof b)'], $keys_json)" >/dev/null
wait_result "$id" bob-4 "$tmp/bob-4.json"
python3 -c 'import json,sys; a,b=(json.load(open(p)) for p in sys.argv[1:3]); assert a["verified"] and a["counter"]==9 and b["verified"], (a, b)' "$tmp/bob-3.json" "$tmp/bob-4.json" \
  || fail "bob after the lost write: $(cat "$tmp/bob-3.json" "$tmp/bob-4.json")"
[ "$(grep -c '"edit", "item", "item-bob"' "$tmp/bw/calls.log")" = "$edits" ] || fail "counters still written after the passkey went missing"
grep -q 'missing after its counter write-back' "$tmp/copper.log" || fail "no log line for the lost passkey"
ok "counters: concurrent signs on one item → 7 and 8 (serialised); UInt32.max saturates, not rewritten; a write-back that loses the passkey stops further writes (logged)"

# 7c. Bitwarden locked: the save target falls back to the keychain, and the
#     vault's passkeys are no longer offered.
bench bw lock >/dev/null
bench eval "$id" "window.__create('gina', 'gina')" >/dev/null
wait_result "$id" gina "$tmp/gina.json"
bench passkeys count >"$tmp/count3.json"
python3 - "$tmp/gina.json" "$tmp/count3.json" "$tmp/bw/state.json" <<'PY2'
import json,sys
r=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); state=json.load(open(sys.argv[3]))
assert not r.get("error") and r["verified"], r
assert c["count"]==1 and c["bitwarden"]==0, c
assert not [i for i in state["items"] if i["login"]["username"]=="gina"], "saved to a locked vault"
PY2
bench eval "$id" "window.__get('locked', ['$(idof a)'], $keys_json)" >/dev/null
wait_result "$id" locked "$tmp/locked.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError", r' "$tmp/locked.json" || fail "locked vault still signed: $(cat "$tmp/locked.json")"
ok "Bitwarden locked: a new passkey goes to the keychain; vault passkeys are not offered"

# 9. A backstage agent tab with only one of Copper's own passkeys for the
#    site: Touch ID would answer yes, but no prompt is shown for a page on no
#    screen — refused, and the agent told why.
gina=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["made"])' "$tmp/gina.json")
mcp "$(call browser_tabs "$new_tab")" >"$tmp/mcp-new2.json"
for _ in {1..40}; do
  evaluate "() => String(document.readyState === 'complete' && !!window.__copperPasskeys)" >"$tmp/mcp-ready.json"
  [ "$(inner "$tmp/mcp-ready.json" 2>/dev/null)" = true ] && break; sleep 0.15
done
evaluate "() => { $(tr '\n' ' ' <<<"$lib") return window.__get('agent-own', ['$gina'], $keys_json, 'preferred'); }" >/dev/null
agent_wait agent-own
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("error")=="NotAllowedError" and r["message"].startswith(sys.argv[2]), r' "$tmp/agent-own.json" "$standard" \
  || fail "backstage tab used Copper's own passkey: $(cat "$tmp/agent-own.json")"
told "Copper's own passkeys there need the person's Touch ID" || fail "the agent was not told about the person's passkey"
ok "backstage agent tab: Copper's own passkey is never offered through a hidden prompt; refused, reason to the agent"

# 8. No private key anywhere Copper or an agent could read it back.
python3 - "$tmp" "$folder" <<'PY'
import base64, glob, json, os, sys
tmp, folder = sys.argv[1], sys.argv[2]
secrets = []
for k in "abcefg":
    std = open(os.path.join(tmp, k + ".pkcs8")).read().strip()
    secrets += [std, std.replace("+", "-").replace("/", "_").rstrip("=")]
state = json.load(open(os.path.join(tmp, "bw", "state.json")))
for item in state["items"]:
    for pk in item["login"].get("fido2Credentials") or []:
        secrets.append(pk["keyValue"])
# Long enough slices that a match is not chance.
needles = [s[40:80] for s in secrets]
paths = [p for p in glob.glob(os.path.join(tmp, "*")) if os.path.isfile(p) and not p.endswith((".pem", ".pkcs8"))]
paths += [os.path.join(tmp, "bw", "calls.log"), os.path.join(tmp, "mcp-all.log")]
paths += [p for p in glob.glob(os.path.join(folder, "**", "*"), recursive=True) if os.path.isfile(p)]
leaks = []
for p in paths:
    try: data = open(p, "rb").read().decode("utf-8", "replace")
    except Exception: continue
    for n in needles:
        if n in data: leaks.append(os.path.relpath(p, tmp) if p.startswith(tmp) else p)
assert not leaks, leaks
print(f"     scanned {len(paths)} files")
PY
ok "no vault private key in bench/MCP output, calls.log argv, the Copper log or the probe world's files"

echo "PASS: Bitwarden passkeys — allowCredentials, discoverable chooser, ES256 verify, counters (serialised, saturating, read-back), UV required, agent rule (backstage + origin-bound armed browser_sign_in, UP only, reprompt excluded) with bare page errors, no off-screen prompts, save-to-Bitwarden (fresh, personal-only join; landed-timeout dedupe) without key exposure"
