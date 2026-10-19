#!/bin/bash
# A WebAuthn-handling extension and Copper's authenticator in real WebKit.
# One synthetic MV3 extension whose MAIN-world script wraps
# navigator.credentials the way 1Password's webauthn-listeners.js does (bound
# references captured at load, then non-configurable accessors), a localhost
# relying party, a fresh headless dev world and at most one scoped test-keychain
# item. No real profile, extension, credentials or Touch ID approval.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="passkey-ext-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""; server=""
bench() { "$root/bench" --world "$world" "$@"; }
cleanup() {
  if [ -n "$pid" ]; then
    if [ -f "$tmp/created-id" ]; then bench passkeys forget --id "$(<"$tmp/created-id")" >/dev/null 2>&1 || true; fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  fi
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
fail() { echo "FAIL $*"; [ -f "$tmp/copper.log" ] && tail -20 "$tmp/copper.log"; exit 1; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && SEARCH_SIGN_IDENTITY=- ./build.sh)
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"

ext="$tmp/fake-webauthn-extension"
mkdir -p "$ext"
cat >"$ext/manifest.json" <<'JSON'
{
  "manifest_version": 3,
  "name": "Synthetic WebAuthn wrapper",
  "version": "1.0",
  "host_permissions": ["http://localhost/*"],
  "content_scripts": [{
    "matches": ["http://localhost/*"],
    "js": ["main.js"],
    "world": "MAIN",
    "run_at": "document_start",
    "all_frames": true
  }]
}
JSON
cat >"$ext/main.js" <<'JS'
// Shaped like 1Password's MAIN-world hook: references bound once at load are
// the fallback, and the hooks are non-configurable accessors nobody can undo.
(function () {
  var c = navigator.credentials;
  window.__fakeExt = { sawCopper: !!window.__copperPasskeys, calls: 0 };
  var fallbackGet = c.get.bind(c), fallbackCreate = c.create.bind(c);
  var conditional = window.PublicKeyCredential && window.PublicKeyCredential.isConditionalMediationAvailable;
  function bytes(list) { return new Uint8Array(list).buffer; }
  function mine(kind) {
    window.__fakeExt.calls++;
    var response = kind === 'get'
      ? { clientDataJSON: bytes([1]), authenticatorData: bytes([2]), signature: bytes([3]), userHandle: null }
      : { clientDataJSON: bytes([1]), attestationObject: bytes([2]),
          getTransports: function () { return ['internal']; },
          getAuthenticatorData: function () { return bytes([2]); },
          getPublicKey: function () { return null; }, getPublicKeyAlgorithm: function () { return -7; } };
    Object.setPrototypeOf(response, (kind === 'get' ? AuthenticatorAssertionResponse : AuthenticatorAttestationResponse).prototype);
    var credential = { id: 'from-extension', rawId: bytes([9]), type: 'public-key', authenticatorAttachment: 'platform',
      response: response, getClientExtensionResults: function () { return {}; } };
    return Object.setPrototypeOf(credential, PublicKeyCredential.prototype);
  }
  async function get(o) { return window.__fakeExtMode === 'accept' ? mine('get') : fallbackGet(o); }
  async function create(o) { return window.__fakeExtMode === 'accept' ? mine('create') : fallbackCreate(o); }
  async function available() { return window.__fakeExtMode === 'accept' ? true : !!(conditional && await conditional.call(PublicKeyCredential)); }
  available.tag = 'extension';
  function hook(parent, name, value) {
    try { Object.defineProperty(parent, name, { configurable: false, enumerable: true, get: function () { return value; }, set: function () {} }); }
    catch (_) {}
  }
  hook(c, 'get', get); hook(c, 'create', create);
  if (window.PublicKeyCredential) hook(window.PublicKeyCredential, 'isConditionalMediationAvailable', available);
})();
JS

python3 - "$tmp/port" <<'PY' >"$tmp/server.log" 2>&1 &
import http.server, pathlib, sys
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data=b'<!doctype html><meta charset="utf-8"><title>Synthetic passkey extension check</title><p>No real credentials.</p>'
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
bench ext-answer yes >/dev/null
bench passkeys count >"$tmp/count.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["count"]==0, "test world must start empty"' "$tmp/count.json"
bench ext-folder "$ext" --yes >/dev/null
for _ in {1..80}; do
  bench extensions >"$tmp/ext.json" 2>/dev/null || true
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d.get("busy") and any(e.get("name")=="Synthetic WebAuthn wrapper" for e in d["extensions"])' "$tmp/ext.json" 2>/dev/null; then break; fi
  sleep 0.25
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(e.get("name")=="Synthetic WebAuthn wrapper" for e in d["extensions"])' "$tmp/ext.json" || fail "extension did not install: $(cat "$tmp/ext.json")"

id=$(bench open "http://localhost:$(<"$tmp/port")/")
loaded=0
for _ in {1..60}; do
  ready=$(bench eval "$id" "({ready: document.readyState === 'complete', bridge: !!window.__copperPasskeys, ext: !!window.__fakeExt})")
  if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["ready"] and d["bridge"] and d["ext"]' "$ready" 2>/dev/null; then loaded=1; break; fi
  sleep 0.1
done
[ "$loaded" = 1 ] || fail "page/bridge/extension not ready: $ready"

js=$(cat <<'JS'
window.__pkResult = {running: true};
(async function () {
  var r = {running: false, sawCopper: window.__fakeExt.sawCopper,
    conditionalHook: PublicKeyCredential.isConditionalMediationAvailable.tag || ''};
  try {
    // The extension handles it: Copper must not be asked (the keychain count
    // is checked from the shell afterwards).
    window.__fakeExtMode = 'accept';
    var a = await navigator.credentials.get({publicKey: {challenge: new Uint8Array([1]), rpId: 'localhost'}});
    var b = await navigator.credentials.create({publicKey: {challenge: new Uint8Array([1]), rp: {id: 'localhost', name: 'S'},
      user: {id: new Uint8Array([4]), name: 'synthetic-only', displayName: 'S'}, pubKeyCredParams: [{type: 'public-key', alg: -7}]}});
    r.acceptGet = a.id; r.acceptCreate = b.id;
    r.acceptInstance = a instanceof PublicKeyCredential && b instanceof PublicKeyCredential;
    r.acceptResponses = a.response instanceof AuthenticatorAssertionResponse && b.response instanceof AuthenticatorAttestationResponse
      && a.response instanceof AuthenticatorResponse;
    r.acceptConditional = await PublicKeyCredential.isConditionalMediationAvailable();
    r.extCalls = window.__fakeExt.calls;
    // The extension declines: the fallback it captured must be the Copper authenticator.
    window.__fakeExtMode = 'decline';
    var created = await navigator.credentials.create({publicKey: {challenge: new Uint8Array([1,2,3]), rp: {id: 'localhost', name: 'S'},
      user: {id: new Uint8Array([4]), name: 'synthetic-only', displayName: 'S'}, pubKeyCredParams: [{type: 'public-key', alg: -7}]}});
    r.id = created.id;
    var got = await navigator.credentials.get({publicKey: {challenge: new Uint8Array([5,6]), rpId: 'localhost',
      allowCredentials: [{type: 'public-key', id: created.rawId}]}});
    r.declineSame = got.id === created.id;
    r.declineInstance = got instanceof PublicKeyCredential && got.response instanceof AuthenticatorAssertionResponse
      && created.response instanceof AuthenticatorAttestationResponse;
    r.declineConditional = await PublicKeyCredential.isConditionalMediationAvailable();
    // No credential for this RP: a clean NotAllowedError, as a platform
    // authenticator with nothing to offer reports.
    try { await navigator.credentials.get({publicKey: {challenge: new Uint8Array([1]), rpId: 'localhost',
      allowCredentials: [{type: 'public-key', id: new Uint8Array([7,7,7])}]}}); r.missing = 'resolved'; }
    catch (e) { r.missing = e.name; }
    r.extCallsAfter = window.__fakeExt.calls;
  } catch (e) { r.error = e.name; r.message = e.message; }
  window.__pkResult = r;
})();
'started';
JS
)
bench passkeys count >"$tmp/count-before.json"
bench eval "$id" "$js" >/dev/null
for _ in {1..100}; do
  bench eval "$id" 'window.__pkResult' >"$tmp/result.json"
  if python3 -c 'import json,sys; assert not json.load(open(sys.argv[1]))["running"]' "$tmp/result.json" 2>/dev/null; then break; fi
  sleep 0.1
done
cat "$tmp/result.json"; echo
python3 - "$tmp/result.json" "$tmp/created-id" <<'PY'
import json, pathlib, sys
r=json.load(open(sys.argv[1]))
if r.get('id'): pathlib.Path(sys.argv[2]).write_text(r['id'])
assert not r.get('running'), ('ceremony timed out', r)
assert r['sawCopper'], ('extension MAIN-world script ran before Copper\'s authenticator', r)
assert r['conditionalHook']=='extension', ('Copper replaced the extension\'s PublicKeyCredential hook', r)
assert not r.get('error'), r
assert r['acceptGet']=='from-extension' and r['acceptCreate']=='from-extension', r
assert r['acceptInstance'] and r['acceptResponses'], r
assert r['acceptConditional'] is True and r['declineConditional'] is False, r
assert r['extCalls']==2 and r['extCallsAfter']==2, r
assert r['declineSame'] and r['declineInstance'], r
assert r['missing']=='NotAllowedError', r
PY
bench passkeys count >"$tmp/count.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["count"]==1, "accepted create must not reach Copper; declined create must"' "$tmp/count.json"
bench passkeys forget --id "$(<"$tmp/created-id")" >/dev/null
bench passkeys count >"$tmp/count.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["count"]==0' "$tmp/count.json"
echo "PASS: Copper installs before the extension's MAIN-world hook; extension-handled get/create skip Copper; declined get/create fall through to Copper; instanceof PublicKeyCredential/Authenticator*Response; missing credential → NotAllowedError; scoped cleanup"
