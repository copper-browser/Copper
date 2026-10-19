#!/bin/bash
# Synthetic WebAuthn ceremonies in real WebKit and the native Swift relay.
# One localhost page, a fresh headless dev world, one scoped test-keychain
# item. No real profile, credentials, Touch ID approval or internet account.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="passkey-rp-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""; server=""
bench() { "$root/bench" --world "$world" "$@"; }
cleanup() {
  if [ -n "$pid" ]; then
    # Only this fixture's service, never Copper's real passkeys. One item
    # is created; the normal test-world forget path proves its cleanup.
    if [ -f "$tmp/created-id" ]; then bench passkeys forget --id "$(<"$tmp/created-id")" >/dev/null 2>&1 || true; fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  fi
  # If RP rejection regresses, the negative create can leave a second
  # synthetic key. A bounded fallback deletes only this test service.
  for _ in {1..4}; do
    security delete-generic-password -s "Copper Passkeys ($world)" >/dev/null 2>&1 || break
  done
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
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && swift build -c release --jobs 4 && SEARCH_SIGN_IDENTITY=- ./build.sh)
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"
python3 - "$tmp/port" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, pathlib, sys
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data=b'<!doctype html><meta charset="utf-8"><title>Synthetic passkey check</title><p>No real credentials.</p>'
        self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Page)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
server=$!
for _ in {1..40}; do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || fail "localhost server"
defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null || fail "headless bench"
bench passkeys answer yes >/dev/null
bench passkeys count >"$tmp/count.json"
python3 - "$tmp/count.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['count']==0, 'test world must start empty'
PY
id=$(bench open "http://localhost:$(<"$tmp/port")/")
loaded=0
for _ in {1..40}; do
  # The bench CLI unwraps the wire reply's `value` before printing it.
  ready=$(bench eval "$id" "({ready: document.readyState === 'complete', bridge: !!window.__copperPasskeys})")
  if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ready"] and d["bridge"]' "$ready" 2>/dev/null; then loaded=1; break; fi
  sleep 0.1
done
[ "$loaded" = 1 ] || fail "page/bridge not ready: $ready"
js=$(cat <<'JS'
window.__pkResult = {running: true};
(async function () {
  try {
    var created = await navigator.credentials.create({publicKey: {
      challenge: new Uint8Array([1,2,3]), rp: {id: 'localhost', name: 'Synthetic'},
      user: {id: new Uint8Array([4]), name: 'synthetic-only', displayName: 'Synthetic'},
      pubKeyCredParams: [{type: 'public-key', alg: -7}]
    }});
    var got = await navigator.credentials.get({publicKey: {
      challenge: new Uint8Array([5,6]), rpId: 'localhost',
      allowCredentials: [{type: 'public-key', id: created.rawId}]
    }});
    // WebAuthn returns DER ECDSA; WebCrypto verifies fixed-width r || s.
    var der = new Uint8Array(got.response.signature), raw = new Uint8Array(64), offset = 2;
    if (der[0] !== 0x30 || der[1] !== der.length - 2) throw new Error('Invalid DER sequence');
    for (var component = 0; component < 2; component++) {
      if (der[offset++] !== 0x02) throw new Error('Invalid DER integer');
      var length = der[offset++], value = der.slice(offset, offset + length);
      offset += length;
      if (value[0] === 0) value = value.slice(1);
      if (!value.length || value.length > 32) throw new Error('Invalid P-256 component');
      raw.set(value, component * 32 + 32 - value.length);
    }
    if (offset !== der.length) throw new Error('Trailing DER data');
    var publicKey = await crypto.subtle.importKey('spki', created.response.getPublicKey(),
      {name: 'ECDSA', namedCurve: 'P-256'}, false, ['verify']);
    var auth = new Uint8Array(got.response.authenticatorData);
    var clientHash = new Uint8Array(await crypto.subtle.digest('SHA-256', got.response.clientDataJSON));
    var signed = new Uint8Array(auth.length + clientHash.length);
    signed.set(auth); signed.set(clientHash, auth.length);
    var signatureVerified = await crypto.subtle.verify({name: 'ECDSA', hash: 'SHA-256'}, publicKey, raw, signed);
    var rpHash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('localhost')));
    var rpHashMatches = rpHash.every((v, i) => v === auth[i]);
    var badCreate = '', badGet = '';
    try { await navigator.credentials.create({publicKey: {
      challenge: new Uint8Array([1]), rp: {id: 'unrelated.test', name: 'Wrong RP'},
      user: {id: new Uint8Array([8]), name: 'synthetic-invalid'}, pubKeyCredParams: [{type: 'public-key', alg: -7}]
    }}); } catch (e) { badCreate = e.name; }
    try { await navigator.credentials.get({publicKey: {
      challenge: new Uint8Array([1]), rpId: 'unrelated.test',
      allowCredentials: [{type: 'public-key', id: created.rawId}]
    }}); } catch (e) { badGet = e.name; }
    window.__pkResult = {running: false, id: created.id, sameCredential: got.id === created.id,
      transports: created.response.getTransports(), signatureVerified: signatureVerified,
      rpHashMatches: rpHashMatches, userVerified: !!(auth[32] & 4),
      badCreate: badCreate, badGet: badGet};
  } catch (e) { window.__pkResult = {running: false, error: e.name, message: e.message}; }
})();
'started';
JS
)
bench eval "$id" "$js" >/dev/null
for _ in {1..80}; do
  bench eval "$id" 'window.__pkResult' >"$tmp/result.json"
  if python3 -c 'import json,sys; assert not json.load(open(sys.argv[1]))["running"]' "$tmp/result.json" 2>/dev/null; then break; fi
  sleep 0.1
done
python3 - "$tmp/result.json" "$tmp/created-id" <<'PY'
import json, pathlib, sys
r=json.load(open(sys.argv[1]))
if r.get('id'): pathlib.Path(sys.argv[2]).write_text(r['id'])
assert not r.get('running'), ('ceremony timed out', r)
assert not r.get('error'), r
assert r['sameCredential'] and r['signatureVerified'], r
assert r['rpHashMatches'] and r['userVerified'], r
assert r['transports']==['internal'], r
assert r['badCreate']=='SecurityError' and r['badGet']=='SecurityError', r
PY
bench passkeys count >"$tmp/count.json"
python3 - "$tmp/count.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['count']==1
PY
bench passkeys forget --id "$(<"$tmp/created-id")" >/dev/null
bench passkeys count >"$tmp/count.json"
python3 - "$tmp/count.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['count']==0
PY
echo "PASS: native create/get, ES256 signature verification, RP hash/UV flag, unrelated RP rejection, internal-only transport, scoped key cleanup"
