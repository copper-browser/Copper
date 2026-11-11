#!/bin/bash
# The 1Password extension in Copper, hop by hop, without anyone's account:
# a COPY of the installed extension loaded under its real id in a fresh
# SEARCH_PROBE world, a stand-in native host, a headless Copper.
#
#   1. The extension loads and runs its native host the way Chrome would
#      (its own origin as the argument) — a stand-in that only listens.
#   2. A canvas tab open beside it: WebKit is never handed a view built
#      without the extension controller ("… is not configured with a
#      WKWebExtensionController" stays out of the log).
#   3. Extensions page › 1Password › Sign In… opens
#      my.1password.com/signin?auth-only=1 and 1Password's content script
#      runs there and gets its answer from the worker.
#   4. A made-up email: the page asks for Secret Key and password.
#   5. What the web app sends the extension after a sign-in
#      (B5SignInSucceeded) reaches the worker with its tab, and the worker
#      takes it as far as 1Password's servers, which turn the made-up
#      Secret Key down (the copy's logging is unredacted for this).
#   6. Use the 1Password App…: the partner-browser request
#      (NmAuthorizePartnerBrowser) reaches the host, the host's answer reaches
#      the extension as the very object the host wrote — never the
#      extension's own question echoed back — and the extension is allowed.
#   7. The worker stays up while 1Password waits on the app (40 s here) and
#      while it owes a message an answer (40 s): Chrome's rules, not WebKit's
#      thirty seconds.
#   8. 1Password's core (WebAssembly) answers after startup, and again after
#      WebKit unloaded the worker and a message started it afresh, with no
#      "WASM is not initialized".
#
# The host is docs/fixtures/onepassword-host.py, which answers as the real
# BrowserSupport does (frames captured with SEARCH_NATIVE_LOG); Copper's side
# of every frame is in $tmp/frames.log (kept with COPPER_1P_KEEP=1).
#
# Needs the network (my.1password.com) and the extension installed in the
# main Copper (or COPPER_1P_EXTENSION=folder). COPPER_1P_REAL_HOST=1 talks to
# the real 1Password BrowserSupport instead of the stand-in (step 6 then shows
# what it answered; a build outside /Applications is refused, steps 7–8 are
# skipped).
# ./build.sh first unless COPPER_SKIP_BUILD=1.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
id=aeblfdkhhhdcdjpifhhbdiojplfjncoa
source_ext="${COPPER_1P_EXTENSION:-$HOME/Library/Application Support/Copper/Extensions/$id}"
world="onepass-$$"
tmp="$(mktemp -d)"
pid=""
started=$(date '+%Y-%m-%d %H:%M:%S')
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  defaults delete "com.collinrijock.copper.test.$world" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.collinrijock.copper.test.$world.plist"
  rm -rf "$HOME/Library/Application Support/Copper ($world)"
  if [ "${COPPER_1P_KEEP:-0}" = 1 ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
  local hash=2166136261 i byte
  for ((i = 0; i < ${#world}; i++)); do
    printf -v byte '%d' "'${world:i:1}"
    hash=$(( ((hash ^ byte) * 16777619) & 0xFFFFFFFF ))
  done
  local stem; stem=$(printf '5E4C%04X-%04X' $((hash >> 16)) $((hash & 0xFFFF)))
  local kit="$HOME/Library/WebKit/com.collinrijock.copper.dev"
  rm -rf "$kit/WebExtensions/$stem-"* "$kit/WebsiteDataStore/$(tr 'A-F' 'a-f' <<<"$stem")-"*
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }

[ -f "$source_ext/manifest.json" ] || { echo "SKIP no 1Password extension at $source_ext"; exit 0; }
if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  if ! (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1; then
    fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
  fi
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
[ -x "$app" ] || fail "build: no Copper executable at $app"

# The stand-in host (docs/fixtures/onepassword-host.py), its frames in $tmp.
mkdir -p "$tmp/hosts"
cp "$root/docs/fixtures/onepassword-host.py" "$tmp/hosts/stand-in"
chmod +x "$tmp/hosts/stand-in"
printf '{"name":"com.1password.1password","path":"%s","type":"stdio","allowed_origins":["chrome-extension://%s/"]}\n' \
  "$tmp/hosts/stand-in" "$id" >"$tmp/hosts/com.1password.1password.json"
hosts=(SEARCH_NATIVE_HOSTS="$tmp/hosts" STANDIN_LOG="$tmp")
[ "${COPPER_1P_REAL_HOST:-0}" = 1 ] && hosts=()

# The copy, under its real id (the native host lets only that origin in).
support="$HOME/Library/Application Support/Copper ($world)"
mkdir -p "$support/Extensions"
cp -R "$source_ext" "$support/Extensions/$id"
version=$(jq -r .version "$support/Extensions/$id/manifest.json")
printf '[{"id":"%s","name":"1Password – Password Manager","version":"%s","enabled":true,"fromStore":false,"pinned":true,"permissions":[]}]\n' \
  "$id" "$version" >"$support/Extensions/installed.json"
# The copy only: the worker's "Error handling request" line says what went
# wrong instead of "<redacted>", by way of an uncaught error the shim lists.
uvx --quiet python - "$support/Extensions/$id/background/background.js" <<'PY' || echo "note: couldn't unredact the copy's errors; step 5 checks less"
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'console.error("[Background]",`${a} Error handling request: ${v(m)}`)'
new = '(setTimeout(()=>{throw new Error("UNREDACTED "+String(m&&(m.message||m))+" "+(()=>{try{return JSON.stringify(m)}catch(e){return ""}})())},0),' + old + ')'
if text.count(old) != 1: sys.exit(1)
text = text.replace(old, new)
# What the partner-browser request's port is handed, word for word (step 6).
port = 'onMessage=e=>{let t=e;if("callbackId"in t.content)'
if text.count(port) == 1:
    text = text.replace(port, 'onMessage=e=>{let t=e;console.warn("COPPER-PORT "+(typeof e)+" "+JSON.stringify(e));if("callbackId"in t.content)')
# A message answered only after ms milliseconds (step 7).
text += '\nchrome.runtime.onMessage.addListener((m, s, reply) => { if (!m || m.copperSlow !== true) return; setTimeout(() => reply({ late: true }), m.ms || 40000); return true; });\n'
open(path, "w", encoding="utf-8").write(text)
PY

defaults write "com.collinrijock.copper.test.$world" bench -bool true
defaults write "com.collinrijock.copper.test.$world" welcomed -bool true
env ${hosts[@]+"${hosts[@]}"} SEARCH_NATIVE_LOG="$tmp/frames.log" SEARCH_NATIVE_LOG_BYTES=600 SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
bench() { "$root/bench" --world "$world" "$@"; }
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"
reported() { bench extensions | jq -r --arg id "$id" '.extensions[] | select(.id == $id) | (.reported + .errors)[]'; }
tab_at() { bench tabs | grep -F -- "$1" | tail -1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{8}$/) { print $i; exit } }'; }

# 1. Loaded, and its native host run as Chrome runs it.
loaded=""
for _ in {1..40}; do
  loaded=$(bench extensions | jq -r --arg id "$id" '.extensions[] | select(.id == $id) | .loaded')
  [ "$loaded" = true ] && break; sleep 0.25
done
[ "$loaded" = true ] || fail "the 1Password copy did not load"
if [ ${#hosts[@]} -gt 0 ]; then
  for _ in {1..60}; do [ -s "$tmp/host-args.log" ] && break; sleep 0.5; done
  grep -qF "chrome-extension://$id/" "$tmp/host-args.log" 2>/dev/null || fail "the extension never ran its native host with its origin"
  echo "ok 1Password $version loaded as $id and ran its native host ($(head -1 "$tmp/host-args.log"))"
else
  echo "ok 1Password $version loaded as $id (real native host)"
fi

# 8. 1Password's core (its WebAssembly) answers once the worker has started:
#    a request the worker hands straight to the core, from one of the
#    extension's own pages.
page=$(bench ext-page "$id" credits.html)
core() {
  bench eval "$page" 'window.__core = null; chrome.runtime.sendMessage({ name: "get-naked-domains-for-urls", data: ["https://accounts.google.com/x"] }).then((r) => { window.__core = r; }, (e) => { window.__core = { threw: String(e) }; }); 1' >/dev/null
  local v=null
  for _ in {1..120}; do v=$(bench eval "$page" 'JSON.stringify(window.__core)' 2>/dev/null || echo null); [ "$v" != null ] && break; sleep 0.25; done
  echo "$v"
}
answer=$(core)
grep -q '"type":"Success"' <<<"$answer" || fail "1Password's core didn't answer after startup: $answer"
if reported | grep -q 'WASM is not initialized'; then fail "WASM is not initialized after startup: $(reported | grep -m1 'WASM is not' | cut -c1-200)"; fi
echo "ok 1Password's core answers after startup ($answer)"

# 2. A canvas tab beside it.
bench canvas open >/dev/null
sleep 3

# 3. Sign In… from the Extensions page.
bench ext-manager onepassword signin >/dev/null
signin=""
for _ in {1..40}; do signin=$(tab_at "https://my.1password.com/signin?auth-only=1"); [ -n "$signin" ] && break; sleep 0.25; done
[ -n "$signin" ] || fail "Sign In… opened no sign-in tab"
answered=""
for _ in {1..80}; do
  answered=$(bench eval "$signin" 'document.body && document.body.dataset.onepasswordExtensionVersion || ""' 2>/dev/null || true)
  [ -n "$answered" ] && break; sleep 0.25
done
[ -n "$answered" ] || fail "1Password's content script did not run on the sign-in page, or the worker never answered it"
echo "ok Sign In… opens the auth-only page; its content script ran and the worker answered (build $answered)"

# 4. A made-up email (tried again until the page's form takes it).
type_email='(() => { const i = document.querySelector("input[type=email]"); const go = [...document.querySelectorAll("button")].find((b) => b.innerText.trim() === "Continue"); if (!i || !go) return "not yet"; const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set; i.focus(); set.call(i, "copper-probe@example.invalid"); i.dispatchEvent(new Event("input", { bubbles: true })); go.click(); return "typed"; })()'
fields=""
for attempt in {1..12}; do
  bench eval "$signin" "$type_email" >/dev/null 2>&1 || true
  for _ in {1..8}; do
    fields=$(bench eval "$signin" '[...document.querySelectorAll("input")].map((i) => i.type + ":" + i.id).join(",")' 2>/dev/null || true)
    grep -q "account-key" <<<"$fields" && grep -q "password:" <<<"$fields" && break 2
    sleep 0.25
  done
done
grep -q "account-key" <<<"$fields" && grep -q "password:" <<<"$fields" || fail "the sign-in page did not ask for Secret Key and password (fields: $fields)"
echo "ok a made-up email gets the Secret Key and password form"

# 5. The web app's hand-over, made up.
bench eval "$signin" 'document.dispatchEvent(new CustomEvent("B5SignInSucceeded", { detail: { authOnly: true, accountUuid: "ABCDEFGHJKLMNPQRSTVWXYZ234", userUuid: "BCDEFGHJKLMNPQRSTVWXYZ2345", email: "copper-probe@example.invalid", domain: "my.1password.com", accountKey: "A3-ABCDEF-GHJKLM-NPQRS-TVWXY-Z2345-6789A", masterPassword: "not-a-real-password" } })); 1' >/dev/null
seen=""
for _ in {1..80}; do
  seen=$(reported | grep -E "UNREDACTED|Exception while handling request <sign-in-succeeded>" || true)
  grep -q "UNREDACTED" <<<"$seen" && break; sleep 0.25
done
grep -q "sign-in-succeeded" <<<"$(reported)" || fail "the worker never handled sign-in-succeeded"
if grep -q "lack of TabInfo\|lack of FrameInfo" <<<"$seen"; then fail "the worker had no tab for the sign-in page: $(grep -m1 'TabInfo\|FrameInfo' <<<"$seen" | cut -c1-200)"; fi
why=$(grep -m1 -o 'UNREDACTED [^@]*' <<<"$seen" | cut -c1-160 || true)
grep -q "SecretKeyIdOrFormatIsWrong\|_handleStartAuthResponse" <<<"$seen" \
  && echo "ok the hand-over reached the worker with its tab and went to 1Password's servers, which refused the made-up Secret Key" \
  || echo "ok the hand-over reached the worker (it answered: ${why:-redacted})"

# 6. Use the 1Password App… — the partner-browser request, and the answer.
bench ext-manager onepassword connect "$id" >/dev/null
if [ ${#hosts[@]} -gt 0 ]; then
  status=""
  for _ in {1..80}; do status=$(bench ext-manager onepassword status | jq -r .onepassword); [ "$status" != asking ] && break; sleep 0.25; done
  grep -qa '^IN .*NmAuthorizePartnerBrowser' "$tmp/host-frames.log" 2>/dev/null || fail "Use the 1Password App… sent no partner-browser request to the host (WebKit's queued-message echo?)"
  grep -qa '> stand-in [0-9]* .*NmAuthorizePartnerBrowser' "$tmp/frames.log" || fail "Copper's frame log has no partner-browser request"
  answer=$(grep -a '^OUT .*"type":"BrowserSupport"' "$tmp/host-frames.log" | tail -1 | cut -d' ' -f3-)
  [ -n "$answer" ] || fail "the stand-in never answered"
  grep -qaF "< stand-in ${#answer} " "$tmp/frames.log" || fail "Copper read no ${#answer}-byte answer from the host"
  heard=$(reported | grep -F "COPPER-PORT " || true)
  grep -qF "COPPER-PORT object $answer" <<<"$heard" || fail "the extension wasn't handed the host's answer as that object (it heard: $(tail -1 <<<"$heard" | cut -c1-200))"
  if grep -q '"invocation"' <<<"$heard"; then fail "the extension heard its own request echoed back: $(grep -m1 '"invocation"' <<<"$heard" | cut -c1-200)"; fi
  if reported | grep -q 't.content is not an Object'; then fail "the extension choked on a port message (t.content is not an Object)"; fi
  [ "$status" = allowed ] || fail "Use the 1Password App… ended $status: $(bench ext-manager onepassword status | jq -r .detail)"
  echo "ok Use the 1Password App…: NmAuthorizePartnerBrowser reached the host, its ${#answer}-byte answer reached the extension as the host wrote it, and the extension was allowed"
else
  for _ in {1..60}; do [ "$(bench ext-manager onepassword status | jq -r .onepassword)" != asking ] && break; sleep 0.5; done
  echo "ok asked the real host: $(bench ext-manager onepassword status | jq -c .)"
  grep -a ' 1Password-BrowserSupport ' "$tmp/frames.log" | tail -4 | cut -c1-260 | sed 's/^/   frame: /'
fi

# 7. The worker kept up: while 1Password waits on the app, and while it owes
#    a page an answer — 40 s each, past WebKit's 30 s unload.
origin() { bench ext-worker "$id" 'return String(performance.timeOrigin)'; }
if [ ${#hosts[@]} -gt 0 ]; then
  echo 40 >"$tmp/delay"
  before=$(origin)
  bench ext-manager onepassword connect "$id" >/dev/null
  status=""
  for _ in {1..70}; do status=$(bench ext-manager onepassword status | jq -r .onepassword); [ "$status" != asking ] && break; sleep 1; done
  rm -f "$tmp/delay"
  [ "$status" = allowed ] || fail "with 1Password answering after 40 s, Use the 1Password App… ended $status"
  [ "$(origin)" = "$before" ] || fail "the worker was unloaded while 1Password was still answering"
  echo "ok the worker stayed up the 40 s 1Password took to answer, and the answer arrived"
fi
before=$(origin)
bench eval "$page" 'window.__slow = null; chrome.runtime.sendMessage({ copperSlow: true, ms: 40000 }).then((r) => { window.__slow = r; }); 1' >/dev/null
slow=null
for _ in {1..60}; do slow=$(bench eval "$page" 'JSON.stringify(window.__slow)'); [ "$slow" != null ] && break; sleep 1; done
[ "$slow" = '{"late":true}' ] || fail "an answer 40 s in the making never arrived (got $slow)"
[ "$(origin)" = "$before" ] || fail "the worker was unloaded while it owed a page an answer"
echo "ok the worker stayed up while it owed a page an answer for 40 s"

# 8. The core again, after WebKit unloads the worker and a message starts it
#    afresh. The web pages go first: their tab events would wake it too, and
#    1Password's own icon code calls the core before it has started then
#    (as it does in Chrome when its worker restarts).
bench close "$signin" >/dev/null 2>&1 || true
up=true
for _ in {1..90}; do up=$(bench extensions | jq -r --arg id "$id" '.extensions[] | select(.id == $id) | .background'); [ "$up" = false ] && break; sleep 1; done
[ "$up" = false ] || fail "WebKit never unloaded the idle worker (or Copper kept it up for nothing)"
before=$(reported | grep -c 'WASM is not initialized' || true)
answer=$(core)
grep -q '"type":"Success"' <<<"$answer" || fail "after a restart the core didn't answer: $answer"
sleep 3
after=$(reported | grep -c 'WASM is not initialized' || true)
[ "$after" = "$before" ] || fail "WASM is not initialized after the worker restarted"
echo "ok after WebKit unloaded the idle worker, a message started it again and the core answered ($answer)"

# The Extensions page with 1Password's details open, when asked for.
if [ -n "${COPPER_1P_PICTURE:-}" ]; then
  bench ext-manager manage >/dev/null; bench ext-manager expand "$id" >/dev/null; sleep 1.5
  bench ext-manager picture "$COPPER_1P_PICTURE" >/dev/null && echo "ok drew the Extensions page to $COPPER_1P_PICTURE"
fi

# 2, checked last: nothing WebKit refused the whole run.
refused=$(log show --start "$started" --style compact --predicate "processID == $pid AND eventMessage CONTAINS \"is not configured with a WKWebExtensionController\"" 2>/dev/null | grep -c "not configured" || true)
[ "${refused:-0}" -eq 0 ] || fail "WebKit was handed $refused views without the extension controller"
echo "ok no view without the extension controller reached WebKit (canvas tab open)"
echo "ok 1Password e2e"
