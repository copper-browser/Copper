#!/bin/bash
# A copied Chrome profile, a headless Copper and a fresh SEARCH_PROBE world.
# No real browser profile, extension or Copper world is read or changed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="flowext-$$"
tmp="$(mktemp -d)"
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  defaults delete "com.collinrijock.copper.test.$world" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/Copper ($world)" "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/chrome"
cp -R "$root/docs/fixtures/flow-chrome/." "$tmp/chrome/"

if ! (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1; then
  echo "FAIL build: $(grep -m 1 'external macro implementation' "$tmp/build.log" | cut -c1-240 || grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
  exit 1
fi
app="$root/build/Copper.app/Contents/MacOS/Copper"
if [ ! -x "$app" ]; then echo "FAIL build: no Copper executable at $app"; exit 1; fi
defaults write "com.collinrijock.copper.test.$world" bench -bool true
defaults write "com.collinrijock.copper.test.$world" welcomed -bool true
SEARCH_PROBE="$world" SEARCH_HEADLESS=1 "$app" >"$tmp/copper.log" 2>&1 &
pid=$!
ready=false
for _ in {1..60}; do
  if "$root/bench" --world "$world" tabs > /dev/null 2>&1; then ready=true; break; fi
  sleep 0.5
done
if [ "$ready" != true ]; then echo "FAIL headless bench did not start (log: $(tail -1 "$tmp/copper.log"))"; exit 1; fi
if ! "$root/bench" --world "$world" flow root --source Chrome --path "$tmp/chrome" >"$tmp/root.json"; then
  echo "FAIL selecting copied Chrome root"; exit 1
fi
if ! jq -e '.source == "Chrome" and .locked == false and (.profiles | index("Default") != null)' "$tmp/root.json" >/dev/null; then
  echo "FAIL Chrome root not recognized: $(jq -c . "$tmp/root.json")"; exit 1
fi
"$root/bench" --world "$world" flow scan --source Chrome >"$tmp/scan.json"
if ! jq -e '.extensions == 8 and (.extensionDetails | length == 8)' "$tmp/scan.json" >/dev/null; then
  echo "FAIL extension count: $(jq -c '{extensions,extensionDetails,error}' "$tmp/scan.json")"; exit 1
fi

failed=0
while IFS='|' read -r id name enabled; do
  if jq -e --arg id "$id" --arg name "$name" --argjson enabled "$enabled" \
    '[.extensionDetails[] | select(.id == $id and .name == $name and .enabled == $enabled)] | length == 1' \
    "$tmp/scan.json" >/dev/null; then
    echo "ok $name ($id): enabled=$enabled"
  else
    echo "FAIL $name ($id): expected enabled=$enabled"
    failed=$((failed + 1))
  fi
done <<'CASES'
chfcgbnkddlkfkhikikhpgobgkldlnge|Legacy on|true
laidppjhcioemjfoccijjjljnoalaknk|Legacy off|false
oapfgjboacmhnapnjcdkknehbgkncfjh|Empty reasons on|true
pkofjabddebjjolininjfgpdpgcoploh|Array reasons off|false
dlemieilhfnlckjhbekagekefgdiffnb|Integer reasons off|false
pdjnbnaahaogmghbglpphffnebkiiihl|Split reasons off|false
dnbmiicpapilleohackflmdamggchhle|No flags on|true
oelmapckalofldpfdcfkiaabgeplebec|Zero reasons on|true
CASES
if [ "$failed" -ne 0 ]; then echo "FAIL $failed/8 extensions"; exit 1; fi
echo "ok 8/8 Chrome extension states in headless Flow scan"
