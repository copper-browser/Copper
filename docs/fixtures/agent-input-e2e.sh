#!/bin/bash
# The hard UI an agent meets, over MCP, in a tab of the agent's own (hung
# backstage, off every screen) — docs/fixtures/agent-input.html.
#
# November 2026 (hill-climb round 1, C6/C2/C4): browser_hover sent its move to
# a method WKWebView doesn't have, so :hover menus never opened and the call
# said "Hovering" anyway; browser_drag pressed a draggable="true" source for
# real (a system drag session a page off screen can't have) and walked a
# sortable list in one turn of the run loop; a ⌘ key the page didn't use went
# back up through the app's key monitor as the user's (⌘T opened the card in
# the user's window); alert/confirm/prompt on an agent's tab were declined
# without a word.
#
#   1. Hover opens a :hover menu; hovering an element under a lid fails loudly.
#   2. HTML5 drag: the drop zone gets the card's data; a non-zone refuses.
#   3. Pointer sortable: alpha goes after charlie, and the order sticks.
#   4. Rich text: ⌘A ⌘B bolds, the page's own ⌘K reaches it as a trusted
#      keydown, ⌘Z undoes, ⌘A ⌘C / ⌘V copies one field into another.
#   5. Dialogs: a question stays open and is reported; browser_handle_dialog
#      answers it, or arms the answer before; moving on closes it; one asked
#      inside browser_evaluate never hangs the call.
#   6. The agent's ⌘T ⌘W ⌘N ⌃Tab Escape never reach the user's window.
#
# Every check runs and the count is printed, so a base build can be scored
# too (COPPER_APP=… COPPER_SKIP_BUILD=1). A fresh SEARCH_PROBE world,
# headless; no network, no real Copper world touched. COPPER_PORT picks the
# MCP port (default: any free one). ./build.sh first unless COPPER_SKIP_BUILD=1.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="agentinput-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.collinrijock.copper.test.$world"
tmp="$(mktemp -d)"
pid=""
clip="$(pbpaste 2>/dev/null || true)"
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  printf %s "$clip" | pbcopy 2>/dev/null || true   # step 4 copies; give the clipboard back
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist"
  rm -rf "$folder" "$tmp"
}
trap cleanup EXIT
die() { echo "FAIL $*"; exit 1; }
passed=0 failed=0
check() { # NAME, then a command that succeeds when it holds
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; passed=$((passed + 1)); else echo "FAIL $name"; failed=$((failed + 1)); fi
}

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || die "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || die "no Copper executable at $app"

mkdir -p "$folder"
port="${COPPER_PORT:-$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")}"
token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
printf '{"enabled":true,"port":%s,"token":"%s","announces":false,"jev":false}' "$port" "$token" >"$folder/agent.json"
defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..60}; do bench tabs >/dev/null 2>&1 && break; sleep 0.5; done
bench tabs >/dev/null 2>&1 || die "headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"

# One tool call; prints the answer's text, "ERROR " first when it is an error.
# Every call names the agent's tab once there is one.
tab=""
mcp() {
  local args="$2"
  [ -n "$tab" ] && args="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.setdefault("tab", sys.argv[2]); print(json.dumps(a))' "$args" "$tab")"
  curl -s -m 30 -X POST "http://127.0.0.1:$port/mcp" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$args}}" |
    python3 -c 'import json,sys
d=json.load(sys.stdin); r=d.get("result") or {}
t="\n".join(c.get("text","") for c in r.get("content",[]) if c.get("type")=="text")
print(("ERROR " if r.get("isError") or "error" in d else "")+(t or json.dumps(d.get("error"))))'
}
# A page value, as JSON text.
js() { mcp browser_evaluate "$(python3 -c 'import json,sys; print(json.dumps({"function": "() => JSON.stringify(" + sys.argv[1] + ")"}))' "$1")"; }
# The ref browser_find gives for visible text.
ref() { mcp browser_find "{\"text\":\"$1\"}" | grep -oE 'ref=e[0-9]+' | head -1 | cut -d= -f2; }
noerror() { ! grep -q '^ERROR' <<<"$1"; }
probe() { bench probe | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))"; }

# The user's own tab, on their (parked) screen.
user="$(bench open "file://$root/docs/fixtures/agent-input.html#user")"
bench wait "$user" 10 >/dev/null
bench select "$user" >/dev/null

opened="$(mcp browser_tabs "{\"action\":\"new\",\"url\":\"file://$root/docs/fixtures/agent-input.html\"}")"
tab="$(grep -oE '\{tab [0-9a-f]{8}\}' <<<"$opened" | head -1 | grep -oE '[0-9a-f]{8}')"
[ -n "$tab" ] || die "the agent could not open its tab: $opened"
grep -q "background" <<<"$opened" || die "the agent's tab is not in the background: $opened"

# 1. Hover.
out="$(mcp browser_hover '{"selector":"#file","element":"File menu"}')"
check "hover answers without error ($(head -c 160 <<<"$out"))" noerror "$out"
check "hover opens the :hover menu" test "$(js 'getComputedStyle(document.querySelector("#file .items")).display')" = '"block"'
out="$(mcp browser_hover '{"selector":"#lidded","element":"Under a lid"}')"
# Either refusal: the hit test before the move (page tools: "covered by span.lid") or the :hover check after it.
check "hover under a lid fails loudly" grep -qE '^ERROR (Hover did not reach|.*covered by)' <<<"$out"

# … and on the user's own tab, in their window (parked, Copper not in front).
own="$tab"; tab="$user"
out="$(mcp browser_hover '{"selector":"#file","element":"File menu"}')"
# WebKit hovers nothing in a window that isn't key, and an agent never makes
# one key: the call must say so and point at a tab of the agent's own.
check "hover on the user's tab behind other apps fails loudly and says why" grep -q '^ERROR Hover did not reach.*work in a tab of your own' <<<"$out"
tab="$own"

# 2. HTML5 drag.
card="$(ref Card)" zone="$(ref 'drop here')" nozone="$(ref 'not a zone')"
out="$(mcp browser_drag "{\"startRef\":\"$card\",\"endRef\":\"$zone\"}")"
check "HTML5 drop lands with its data" test "$(js 'document.getElementById("zone").textContent')" = '"dropped card-42"'
out="$(mcp browser_drag "{\"startRef\":\"$card\",\"endRef\":\"$nozone\"}")"
check "HTML5 drop on a non-zone is refused" grep -q '^ERROR .*did not take the drop' <<<"$out"

# 3. Pointer sortable.
one="$(ref alpha)" three="$(ref charlie)"
out="$(mcp browser_drag "{\"startRef\":\"$one\",\"endRef\":\"$three\"}")"
check "sortable: alpha moves after charlie ($(js 'document.getElementById("list").dataset.order'))" \
  test "$(js 'document.getElementById("list").dataset.order')" = '"bravo,charlie,alpha,delta"'

# 4. Rich text and ⌘ keys.
mcp browser_click '{"selector":"#ed","element":"editor"}' >/dev/null
mcp browser_press_key '{"key":"Meta+a"}' >/dev/null
mcp browser_press_key '{"key":"b","modifiers":["Meta"]}' >/dev/null
check "⌘A ⌘B bolds the editor ($(js 'document.getElementById("ed").innerHTML'))" \
  grep -qiE '<b>hello world</b>|font-weight: ?(bold|700)' <<<"$(js 'document.getElementById("ed").innerHTML')"
mcp browser_press_key '{"key":"Meta+k"}' >/dev/null
check "the page's own ⌘K reaches it, trusted" test "$(js 'document.getElementById("ed").dataset.link + " " + keys.includes("Meta+k")')" = '"yes true"'
mcp browser_press_key '{"key":"Meta+z"}' >/dev/null
check "⌘Z undoes the bold ($(js 'document.getElementById("ed").innerHTML'))" test "$(js 'document.getElementById("ed").innerHTML')" = '"hello world"'
mcp browser_click '{"selector":"#a","element":"field a"}' >/dev/null
mcp browser_press_key '{"key":"Meta+a"}' >/dev/null
mcp browser_press_key '{"key":"Meta+c"}' >/dev/null
mcp browser_click '{"selector":"#b","element":"field b"}' >/dev/null
mcp browser_press_key '{"key":"Meta+v"}' >/dev/null
check "⌘A ⌘C, ⌘V copies field a into field b" test "$(js 'document.getElementById("b").value')" = '"copy me"'

# 5. Dialogs. Left open after the click, as in Playwright, until answered or
# the agent moves on; or armed before it.
out="$(mcp browser_click '{"selector":"#alert","element":"Alert"}')"
check "an alert is reported open" grep -q '^- alert "Saved!" → open' <<<"$out"
out="$(mcp browser_snapshot '{"interactive":true}')"
check "moving on closes it with OK, and says so" grep -q '^- alert "Saved!" → OK (you moved on' <<<"$out"
out="$(mcp browser_click '{"selector":"#confirm","element":"Confirm"}')"
check "a confirm is reported open" grep -q '^- confirm "Delete it?" → open' <<<"$out"
out="$(mcp browser_handle_dialog '{"accept":true}')"
check "browser_handle_dialog accepts the open confirm" grep -q '^Accepted: the confirm "Delete it?"' <<<"$out"
mcp browser_handle_dialog '{"accept":false}' >/dev/null
out="$(mcp browser_click '{"selector":"#confirm","element":"Confirm"}')"
check "an armed dismiss answers the next confirm at once" grep -q '^- confirm "Delete it?" → dismissed$' <<<"$out"
mcp browser_handle_dialog '{"accept":true,"promptText":"Ada"}' >/dev/null
out="$(mcp browser_click '{"selector":"#prompt","element":"Prompt"}')"
check "an armed prompt gets its text" grep -q '^- prompt "Your name?" → accepted with "Ada"' <<<"$out"
check "the page saw every answer ($(js 'said'))" test "$(js 'said')" = '["alert done","confirm true","confirm false","prompt Ada"]'
out="$(mcp browser_evaluate '{"function":"() => String(prompt(\"Inside a script?\"))"}')"
check "a dialog inside browser_evaluate never hangs it; its answer is the value alone" test "$out" = null
out="$(mcp browser_snapshot '{"interactive":true}')"
check "… and the next answer reports it" grep -q '^- prompt "Inside a script?" → dismissed — a script of Copper' <<<"$out"

# 6. The agent's shortcuts stay in its page.
mcp browser_evaluate '{"function":"() => { document.activeElement && document.activeElement.blur(); return 1 }"}' >/dev/null
tabs_before="$(probe tabCount)"; active_before="$(probe active)"; windows_before="$(bench probe | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["windows"]))')"
for key in Meta+t Meta+w Meta+n Control+Tab Escape; do mcp browser_press_key "{\"key\":\"$key\"}" >/dev/null; done
sleep 1
windows_after="$(bench probe | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["windows"]))')"
check "⌘T opened no card in the user's window" test "$(probe launching)" = False
check "⌘W ⌃Tab left the user's tabs alone ($tabs_before → $(probe tabCount), active $active_before → $(probe active))" \
  test "$(probe tabCount)/$(probe active)" = "$tabs_before/$active_before"
check "⌘N opened no window ($windows_before → $windows_after)" test "$windows_after" = "$windows_before"
check "the agent's own tab is still open" grep -q "{tab $tab}" <<<"$(mcp browser_tabs '{"action":"list"}')"

echo "$passed passed, $failed failed"
[ "$failed" = 0 ] && echo PASS || exit 1
