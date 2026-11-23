#!/bin/bash
# Approve cards end to end over MCP (Fork/MCP/Approve.swift): a headless probe
# world with SEARCH_APPROVE=ask (a test world's switches are off, and headless
# never asks, unless told to), the fixture checkout (docs/fixtures/approve/).
#
#   1. A plain click (Order details) goes in at once: no card.
#   2. browser_click on Pay $42.00 waits: the card says the agent, the host,
#      the button, $42.00 and •••• 4242. Deny → the call fails "denied" and
#      nothing was paid.
#   3. Again, Approve → the call says "approved" and the page was paid once.
#   4. Again, no answer: after approve.timeout (5 s here) it counts as denied.
#   5. browser_press_key Enter in the card form asks the same way (Deny).
#
# APPROVE_SHOT=PATH also takes a picture of the window while the card waits.
# COPPER_APP=/path/Copper.app runs another build. Ports: MCP $COPPER_MCP_PORT
# (4143), pages $FIXTURE_PORT (4144).   COPPER_SKIP_BUILD=1 docs/fixtures/approve-e2e.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="${APPROVE_WORLD:-approve-$$}"
suite="com.collinrijock.copper.test.$world"
folder="$HOME/Library/Application Support/Copper ($world)"
mcp_port="${COPPER_MCP_PORT:-4143}"
port="${FIXTURE_PORT:-4144}"
tmp="$(mktemp -d)"
pid="" server=""
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
fail() { echo "FAIL $*"; tail -5 "$tmp/copper.log" 2>/dev/null; exit 1; }
bench() { "$root/bench" --world "$world" "$@"; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
app="${COPPER_APP:-$root/build/Copper.app}/Contents/MacOS/Copper"
[ -x "$app" ] || fail "no Copper executable at $app"

(cd "$root/docs/fixtures/approve" && exec python3 -m http.server "$port" --bind 127.0.0.1) >"$tmp/server.log" 2>&1 &
server=$!
for _ in {1..40}; do curl -fsS -o /dev/null "http://127.0.0.1:$port/checkout.html" 2>/dev/null && break; sleep 0.1; done
curl -fsS -o /dev/null "http://127.0.0.1:$port/checkout.html" || fail "page server on $port"

mkdir -p "$folder"
token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
printf '{"enabled":true,"port":%s,"token":"%s","announces":false,"jev":false}' "$mcp_port" "$token" >"$folder/agent.json"
defaults write "$suite" bench -bool true
defaults write "$suite" welcomed -bool true
defaults write "$suite" approve.timeout -float 5
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 SEARCH_HEADLESS_SIZE=1440x900 SEARCH_MCP_PORT="$mcp_port" SEARCH_APPROVE=ask \
  SEARCH_PROBE_DPR="${SEARCH_PROBE_DPR:-}" "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
for _ in {1..80}; do bench tabs >/dev/null 2>&1 && break; sleep 0.25; done
bench tabs >/dev/null 2>&1 || fail "headless bench did not start"
# The picture shows the column too, for its "1 needs you".
[ -n "${APPROVE_SHOT:-}" ] && bench ui sidebar on >/dev/null

# One MCP call: prints "ok|err<TAB>text".
mcp() {
  local raw
  raw=$(curl -s -m 60 -X POST "http://127.0.0.1:$mcp_port/mcp" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2,\"_meta\":{\"copper/agent\":{\"session\":\"e2e\",\"label\":\"Claude\"}}}}")
  python3 -c '
import json, sys
raw = sys.argv[1]
line = next((l[5:] for l in raw.splitlines() if l.startswith("data:")), raw)
r = json.loads(line).get("result", {})
text = " ".join(c.get("text", "") for c in r.get("content", []))
print(("err" if r.get("isError") else "ok") + "\t" + text.replace("\n", " "))' "$raw"
}
asks() { bench agent approve 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("asks", [])))'; }
wait_ask() { for _ in {1..60}; do [ "$(asks)" != "[]" ] && return 0; sleep 0.1; done; return 1; }
title() { mcp browser_evaluate '{"function":"() => document.title"}' | cut -f2; }

r=$(mcp browser_navigate "{\"url\":\"http://127.0.0.1:$port/checkout.html\"}")
[ "${r%%$'\t'*}" = ok ] || fail "navigate: $r"

# 1. Not a commit: no card.
r=$(mcp browser_click '{"selector":"#details","element":"Order details"}')
[ "${r%%$'\t'*}" = ok ] && [ "$(asks)" = "[]" ] || fail "plain click: $r"
echo "ok 1 a plain click goes in with no card"

# 2. Deny.
mcp browser_click '{"selector":"#go","element":"Pay"}' >"$tmp/r2" &
call=$!
wait_ask || fail "no card for Pay"
card=$(asks)
echo "   card: $card"
python3 - "$card" <<'PY' || fail "card fields: $card"
import json, sys
a = json.loads(sys.argv[1])[0]
assert a["kind"] == "pay" and a["label"] == "Pay $42.00" and a["amount"] == "$42.00" and a["card"] == "4242", a
assert a["host"].startswith("127.0.0.1") and a["agent"] == "Claude", a
PY
if [ -n "${APPROVE_SHOT:-}" ]; then sleep 0.6; bench canvas picture "$APPROVE_SHOT" >/dev/null && echo "   picture: $APPROVE_SHOT"; fi
bench agent approve no >/dev/null
wait "$call"
r=$(cat "$tmp/r2")
[ "${r%%$'\t'*}" = err ] && [[ "$r" == *"denied"* ]] || fail "deny: $r"
[[ "$(title)" != *paid* ]] || fail "paid after deny"
echo "ok 2 deny: $(echo "$r" | cut -f2 | cut -c1-120)"

# 3. Approve: paid once.
mcp browser_click '{"selector":"#go","element":"Pay"}' >"$tmp/r3" &
call=$!
wait_ask || fail "no card the second time"
bench agent approve yes >/dev/null
wait "$call"
r=$(cat "$tmp/r3")
[ "${r%%$'\t'*}" = ok ] && [[ "$r" == *approved* ]] || fail "approve: $r"
sleep 0.3
[[ "$(title)" == *"paid 1"* ]] || fail "title after approve: $(title)"
echo "ok 3 approve: paid once ($(echo "$r" | cut -f2 | cut -c1-90))"

# 4. No answer: denied after the timeout.
started=$(date +%s)
r=$(mcp browser_click '{"selector":"#go","element":"Pay"}')
took=$(( $(date +%s) - started ))
[ "${r%%$'\t'*}" = err ] && [[ "$r" == *"No answer"* ]] && [ "$took" -ge 4 ] || fail "timeout (${took}s): $r"
[[ "$(title)" == *"paid 1"* ]] || fail "paid on timeout"
echo "ok 4 no answer in ${took}s counts as denied"

# 5. Return in the card form asks too.
mcp browser_evaluate '{"function":"() => { document.getElementById(\"name\").focus(); return true }"}' >/dev/null
mcp browser_press_key '{"key":"Enter"}' >"$tmp/r5" &
call=$!
wait_ask || fail "no card for Return"
bench agent approve no >/dev/null
wait "$call"
r=$(cat "$tmp/r5")
[ "${r%%$'\t'*}" = err ] && [[ "$r" == *denied* ]] && [[ "$(title)" == *"paid 1"* ]] || fail "Return: $r"
echo "ok 5 Return in a card form asks, deny holds it"
echo "PASS approve-e2e"
