#!/bin/bash
# Real WKWebExtension lifecycle in an isolated headless dev world. The
# incompatible extensions are synthetic, inert copies: no Apple helper,
# passwords, website sign-ins, extension downloads or real Copper state.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="login-recovery-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
tmp="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  defaults delete "com.officecommun.search.test.$world" >/dev/null 2>&1 || true
  rm -rf "$folder" "$tmp"
  # Store.probeStore's FNV-1a world prefix, only this fixture's stores.
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
fail() { echo "FAIL $*"; exit 1; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then (cd "$root" && SEARCH_SIGN_IDENTITY=- ./build.sh); fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build the dev app first"

python3 - "$folder" "$root" "$tmp" <<'PY'
import json, pathlib, re, sys
folder, root, tmp = map(pathlib.Path, sys.argv[1:])
key = re.search(r'private let iCloudPublicKey = "([^"]+)"', (root/'Tests/SearchTests/LoginRecoveryTests.swift').read_text()).group(1)
items = []
for id, name, manifest_key in [('pejdijmoenmkgeppbflobdenhhabjlaj', 'Synthetic iCloud store copy', None),
                              ('local-apple', 'Synthetic unpacked copy', key),
                              ('local-safe', 'Safe fixture', None)]:
    target = folder/'Extensions'/id
    target.mkdir(parents=True)
    manifest = {'manifest_version': 3, 'name': name, 'version': '1.0', 'action': {'default_title': name}}
    if manifest_key: manifest['key'] = manifest_key
    (target/'manifest.json').write_text(json.dumps(manifest))
    (target/'keep.txt').write_text('extension data must survive')
    items.append({'id': id, 'name': name, 'version': '1.0', 'enabled': True, 'fromStore': False, 'permissions': []})
(folder/'Extensions/installed.json').write_text(json.dumps(items))
rejected = tmp/'rejected'
rejected.mkdir()
(rejected/'manifest.json').write_text(json.dumps({'manifest_version': 3, 'name': 'Unpacked rejected', 'version': '1.0', 'key': key}))
PY

defaults write "com.officecommun.search.test.$world" bench -bool true
defaults write "com.officecommun.search.test.$world" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
start() {
  SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
  pid=$!
  for _ in {1..60}; do bench tabs >/dev/null 2>&1 && return; sleep 0.5; done
  fail "headless bench did not start"
}
check_state() {
  bench extensions >"$tmp/extensions.json"
  python3 - "$tmp/extensions.json" "$folder" <<'PY'
import json, pathlib, sys
states = {x['id']: x for x in json.load(open(sys.argv[1]))['extensions']}
folder = pathlib.Path(sys.argv[2])/'Extensions'
assert len(states) == 3, states.keys()
for id in ('pejdijmoenmkgeppbflobdenhhabjlaj', 'local-apple'):
    assert not states[id]['enabled'] and not states[id]['loaded'], states[id]
    assert any('incompatible' in e for e in states[id]['reported']), states[id]
    assert (folder/id/'keep.txt').read_text() == 'extension data must survive'
assert states['local-safe']['enabled'] and states['local-safe']['loaded'], states['local-safe']
saved = {x['id']: x for x in json.loads((folder/'installed.json').read_text())}
assert not saved['local-apple']['enabled'] and not saved['pejdijmoenmkgeppbflobdenhhabjlaj']['enabled']
PY
}
start
for _ in {1..40}; do
  bench extensions >"$tmp/extensions.json"
  python3 - "$tmp/extensions.json" <<'PY' && break || true
import json, sys
assert any(x['id'] == 'local-safe' and x['loaded'] for x in json.load(open(sys.argv[1]))['extensions'])
PY
  sleep 0.25
done
check_state
echo "ok startup migration: blocked copies stay off, safe extension loads, data preserved"

for id in pejdijmoenmkgeppbflobdenhhabjlaj local-apple; do
  bench ext-enable "$id" on >"$tmp/enable.json"
  python3 - "$tmp/enable.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['enabled'] is False
PY
  bench ext-reload "$id" >/dev/null
done
bench ext-add pejdijmoenmkgeppbflobdenhhabjlaj --yes >/dev/null
bench ext-folder "$tmp/rejected" --yes >/dev/null
sleep 2
check_state
[ "$(find "$folder/Extensions" -maxdepth 1 -name '.staging-*' | wc -l | tr -d ' ')" = 0 ] || fail "rejected install left staging files"
echo "ok re-enable/reload refused; store and keyed-folder admission refused without loading"

kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""
start
sleep 2
check_state
echo "PASS: restart preserves disabled state and extension data"
