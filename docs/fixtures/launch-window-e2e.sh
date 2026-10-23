#!/bin/bash
# No launch without a browser window (Fork/LaunchWatchdog.swift).
#
# October 2026: v1.0.20261020.66 relaunched by its updater came up running, in
# front, with its session loaded — and no browser window; ⌘Q and the Dock did
# the same, and the Dock click, the Dock menu's New Window and ⌘N did nothing.
# Development builds never showed it: `./build.sh` stamps the binary as built
# against macOS 14, a release (Xcode on macos-15) against 15.5, and SwiftUI
# opens its first window differently for the two (against 15.5 it leaves it to
# AppKit's launch event). So this runs a copy of the build stamped like a
# release, under a bundle id of its own (its own saved window state, never the
# main world's), in a probe world of its own, launched the way the updater
# relaunches (`open -n`) but in the background (`-g`), so nothing here takes
# your focus:
#
#   0. After a clean quit (no window state kept), a background launch gets its
#      window from AppKit — the Room, where the restored page starts, is a panel
#      and no longer counts — and the watchdog stays quiet. After a kill (state
#      kept), a background launch is left to window restoration, which brings
#      none back: the watchdog opens it, says so in trail.log, and the probe
#      does not take the front.
#   1. A decoy window up before AppKit's decision (COPPER_TEST_BLOCK_LAUNCH_WINDOW=1,
#      test worlds only — what the Room did when it was an NSWindow): no window
#      until the watchdog's look, then one, and only one after its second look.
#   2. Watchdog off, decoy up (so the reopen says "a window is showing", as the
#      Backstage room's did): a reopen event — the Dock click — opens the window.
#   3. …and more reopen events and Dock clicks open no second one.
#   4. Watchdog off, decoy taken down after the launch (`=brief`): a reopen that
#      AppKit answers itself too opens exactly one (both asks land on the one
#      `Window` scene).
#   5. Watchdog off, decoy gone: an agent's page hung backstage, then a reopen:
#      one window.
#   6. Watchdog off: ⌘N (`windows new`) opens it.
#   7. Watchdog off: the Dock menu's New Window (`windows dockmenu`) opens it.
#   8. Headless: no watchdog, no window on any screen.
#   F. COPPER_FIXTURE_FOREGROUND=1 only (it takes the front for a moment): a
#      foreground launch with a page restored in the Room, watchdog off, gets
#      its window from AppKit itself — the Room is a panel and no longer counts.
#
# ./build.sh first unless COPPER_SKIP_BUILD=1. No Docker; nothing here touches
# the main world, the keychain or the installed Copper.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
world="launchwin-$$"
folder="$HOME/Library/Application Support/Copper ($world)"
domain="com.officecommun.search.test.$world"
port="${FIXTURE_PORT:-$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")}"
tmp="$(mktemp -d)"
pid=""
bundle="com.collinrijock.copper.dev.launchwin"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  stop
  defaults delete "$domain" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$domain.plist" "$HOME/Library/Preferences/$bundle.plist"
  [ -d "$tmp/Copper.app" ] && "$lsregister" -u "$tmp/Copper.app" >/dev/null 2>&1 || true
  rm -rf "$folder" "$tmp" "$HOME/Library/WebKit/$bundle" "$HOME/Library/Caches/$bundle" "$HOME/Library/HTTPStorages/$bundle" \
    "$HOME/Library/HTTPStorages/$bundle.binarycookies"
}
stop() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$pid" 2>/dev/null || true
    pid=""
  fi
}
trap cleanup EXIT
fail() { echo "FAIL $*"; [ -f "$folder/logs/trail.log" ] && tail -5 "$folder/logs/trail.log" | sed 's/^/   trail: /'; exit 1; }

if [ "${COPPER_SKIP_BUILD:-0}" != 1 ]; then
  (cd "$root" && ./build.sh) >"$tmp/build.log" 2>&1 || fail "build: $(grep -m 1 'error:' "$tmp/build.log" | cut -c1-240)"
fi
[ -x "$root/build/Copper.app/Contents/MacOS/Copper" ] || fail "no build/Copper.app"

# The build, stamped as a release is (built against the macOS 15.5 SDK), under
# a bundle id of its own.
app="$tmp/Copper.app"
cp -R "$root/build/Copper.app" "$app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$app/Contents/Info.plist"
xattr -cr "$app"
codesign -d --entitlements :- "$root/build/Copper.app" >"$tmp/entitlements.plist" 2>/dev/null
vtool -set-build-version macos 14.0 15.5 -replace -output "$app/Contents/MacOS/Copper.stamped" "$app/Contents/MacOS/Copper" 2>/dev/null
mv "$app/Contents/MacOS/Copper.stamped" "$app/Contents/MacOS/Copper"
codesign --force -s - --options runtime --entitlements "$tmp/entitlements.plist" "$app" >/dev/null 2>&1
otool -l "$app/Contents/MacOS/Copper" | grep -A4 LC_BUILD_VERSION | grep -q "sdk 15.5" || fail "could not stamp the copy as a release"

# Browser windows of a process on a display (layer 0, ordered in, at least
# 600×400, on some screen) — the rooms are parked off every screen — and one
# kAEReopenApplication aimed at a pid, which is what a Dock click sends.
cat >"$tmp/wins.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let pid = pid_t(args[2])!
if args[1] == "count" {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var n = 0
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        var displays: UInt32 = 0
        CGGetDisplaysWithRect(r, 0, nil, &displays)
        if r.width >= 600, r.height >= 400, displays > 0 { n += 1 }
    }
    print(n)
} else if args[1] == "front" {
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
} else if args[1] == "quit" {
    _ = NSRunningApplication(processIdentifier: pid)?.terminate()
} else {
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                       targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                       returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try event.sendEvent(options: NSAppleEventDescriptor.SendOptions.noReply, timeout: 5)
}
SWIFT
SDKROOT="${SDKROOT:-}" swiftc -O "$tmp/wins.swift" -o "$tmp/wins" 2>"$tmp/swiftc.log" || fail "helper: $(head -1 "$tmp/swiftc.log")"
wins() { "$tmp/wins" count "$pid"; }

defaults write "$domain" bench -bool true
defaults write "$domain" welcomed -bool true
bench() { "$root/bench" --world "$world" "$@"; }

# A world with a page to restore, so the launch parks it in the Room.
fresh_world() {
  rm -rf "$folder"
  mkdir -p "$folder"
  cat >"$folder/session.json" <<'JSON'
{"tabs":[{"url":"https://example.com/","title":"Example","active":true},{"url":"https://example.org/","title":"Example org"}],"active":0}
JSON
}

# launch [ENV=VALUE…] — `open -n` in the background, like the updater; waits
# for the world's lock and the bench.
launch() {
  local envs=(--env "SEARCH_PROBE=$world" --env "SEARCH_MCP_PORT=$port")
  for kv in "$@"; do envs+=(--env "$kv"); done
  rm -f "$folder/instance.lock"
  open -n -g "${envs[@]}" "$app"
  for _ in {1..80}; do
    pid=$(cat "$folder/instance.lock" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && break
    pid=""; sleep 0.25
  done
  [ -n "$pid" ] || fail "the probe never took its world's lock"
  for _ in {1..60}; do bench windows showing >/dev/null 2>&1 && return; sleep 0.25; done
  fail "the bench never answered"
}

watchdog_lines() { grep -c " $pid launch-watchdog " "$folder/logs/trail.log" 2>/dev/null || true; }
recovery() { grep " $pid window-recovery " "$folder/logs/trail.log" 2>/dev/null | tail -1 || true; }
until_windows() { for _ in {1..40}; do [ "$(wins)" = "$1" ] && return 0; sleep 0.25; done; return 1; }
front() { "$tmp/wins" front 0; }
# The probe never takes the front from what you were using.
kept_front() { local now; now=$(front); [ "$now" != "$pid" ] || [ "$1" = "$pid" ]; }

# 0. Background launches, without and with window state to restore.
fresh_world
launch
until_windows 1 || fail "0: $(wins) browser windows after the first launch"
"$tmp/wins" quit "$pid"
for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
kill -0 "$pid" 2>/dev/null && fail "0: the probe did not quit"
pid=""
launch
until_windows 1 || fail "0a: $(wins) browser windows after a background launch with nothing to restore"
sleep 5.5
[ "$(watchdog_lines)" = 0 ] || fail "0a: the watchdog had to open the window — AppKit opened none (the Room still counts?)"
[ "$(wins)" = 1 ] || fail "0a: $(wins) windows"
echo "ok 0a after a clean quit, a background launch with a page restored in the Room got its window from AppKit; watchdog quiet"
kill -9 "$pid"; sleep 0.5; pid=""
before=$(front)
launch
until_windows 1 || fail "0b: $(wins) browser windows after a background launch with window state to restore"
sleep 5.5
[ "$(wins)" = 1 ] || fail "0b: $(wins) windows after the watchdog's second look"
[ "$(watchdog_lines)" -le 1 ] || fail "0b: the watchdog fired $(watchdog_lines) times"
kept_front "$before" || fail "0b: the probe took the front"
line=$(grep " $pid launch-watchdog " "$folder/logs/trail.log" | head -1 || true)
if [ -n "$line" ]; then
  echo "ok 0b after a kill, a background launch left to window restoration got none from AppKit; the watchdog opened the one window (${line#* * }); the front stayed where it was"
else
  echo "ok 0b after a kill, a background launch got one window (restored by AppKit this time; the watchdog had nothing to do)"
fi
stop

# 1. A decoy window up before the decision.
fresh_world
before=$(front)
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=1 COPPER_LAUNCH_WATCHDOG_DELAY=4
sleep 1.5
[ "$(wins)" = 0 ] || fail "1: $(wins) windows before the watchdog's look"
until_windows 1 || fail "1: the watchdog did not bring a window ($(wins) on screen)"
grep " $pid launch-watchdog " "$folder/logs/trail.log" | head -1 | grep -q "check=after-4s.*action=opened-first-window" || fail "1: no after-4s watchdog line"
sleep 4.5
[ "$(wins)" = 1 ] || fail "1: $(wins) windows after the watchdog's second look"
[ "$(watchdog_lines)" = 1 ] || fail "1: the watchdog fired $(watchdog_lines) times"
kept_front "$before" || fail "1: the probe took the front"
echo "ok 1 decoy up: no window until the watchdog's look at 4 s, then one, still one after its second look"
stop

# 2. Watchdog off, decoy up: the Dock click.
fresh_world
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=1 COPPER_LAUNCH_WATCHDOG=off
sleep 4
[ "$(wins)" = 0 ] || fail "2: $(wins) windows with the watchdog off — nothing to recover"
echo "ok 2a watchdog off: running, no browser window (the field's state)"
"$tmp/wins" reopen "$pid"
until_windows 1 || fail "2: a reopen event left $(wins) windows"
recovery | grep -q "via=dock" || fail "2: no window-recovery via=dock line ($(recovery))"
echo "ok 2b a reopen event, with a window AppKit counts as showing, opened the first window: $(recovery | cut -d' ' -f3-)"

# 3. …and never a second.
"$tmp/wins" reopen "$pid"; sleep 1; bench windows dock >/dev/null; sleep 1; "$tmp/wins" reopen "$pid"; sleep 1.5
[ "$(wins)" = 1 ] || fail "3: $(wins) windows after more reopens"
echo "ok 3 with the window up, two reopen events and a Dock click leave one window"
stop

# 4. Watchdog off, decoy gone after the launch: AppKit's own reopen and Copper's make one window.
fresh_world
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=brief COPPER_LAUNCH_WATCHDOG=off
sleep 4
[ "$(wins)" = 0 ] || fail "4: $(wins) windows with the watchdog off"
"$tmp/wins" reopen "$pid"
until_windows 1 || fail "4: a reopen event left $(wins) windows"
sleep 2
[ "$(wins)" = 1 ] || fail "4: $(wins) windows a moment after the reopen"
echo "ok 4 a plain reopen with no window ever made opened exactly one"
stop

# 5. Watchdog off: an agent's page backstage (the Backstage room up), then a reopen.
fresh_world
token=$(python3 -c "import secrets; print(secrets.token_hex(32))")
printf '{"enabled":true,"port":%s,"token":"%s","announces":false,"jev":false}' "$port" "$token" >"$folder/agent.json"
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=brief COPPER_LAUNCH_WATCHDOG=off
mcp() { curl -s -m 20 -X POST "http://127.0.0.1:$port/mcp" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
for _ in {1..40}; do mcp browser_tabs '{"action":"list"}' | grep -q "Open tabs" && break; sleep 0.25; done
other=$(mcp browser_tabs '{"action":"list"}' | grep -oE '\{tab [0-9a-f]{8}\}' | sed -n 2p | grep -oE '[0-9a-f]{8}')
[ -n "$other" ] || fail "5: no second tab over MCP"
mcp browser_get_text "{\"tab\":\"$other\"}" | grep -q '"isError":false' || fail "5: the agent's read failed"
sleep 1
[ "$(wins)" = 0 ] || fail "5: $(wins) windows before the reopen"
"$tmp/wins" reopen "$pid"
until_windows 1 || fail "5: with an agent's page backstage, a reopen left $(wins) windows"
echo "ok 5 with an agent's page hung backstage, a reopen opened the first window"
stop

# 6. Watchdog off: ⌘N.
fresh_world
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=1 COPPER_LAUNCH_WATCHDOG=off
sleep 4
[ "$(wins)" = 0 ] || fail "6: $(wins) windows with the watchdog off"
bench windows new >/dev/null
until_windows 1 || fail "6: ⌘N left $(wins) windows"
recovery | grep -q "via=new-window" || fail "6: no window-recovery via=new-window line"
echo "ok 6 ⌘N with no window ever made opened the first one"
stop

# 7. Watchdog off: the Dock menu's New Window.
fresh_world
launch COPPER_TEST_BLOCK_LAUNCH_WINDOW=1 COPPER_LAUNCH_WATCHDOG=off
sleep 4
[ "$(wins)" = 0 ] || fail "7: $(wins) windows with the watchdog off"
bench windows dockmenu >/dev/null
until_windows 1 || fail "7: the Dock menu left $(wins) windows"
recovery | grep -q "via=dock" || fail "7: no window-recovery line"
echo "ok 7 the Dock menu's New Window with no window ever made opened the first one"
stop

# 8. Headless: nothing.
fresh_world
launch SEARCH_HEADLESS=1 COPPER_TEST_BLOCK_LAUNCH_WINDOW=1 COPPER_LAUNCH_WATCHDOG_DELAY=0.5
sleep 6
[ "$(wins)" = 0 ] || fail "8: a headless run has $(wins) windows on screen"
[ "$(watchdog_lines)" = 0 ] || fail "8: the watchdog fired headless"
bench windows watchdog | tr -d ' \n' | grep -q '"armed":false' || fail "8: watchdog armed headless: $(bench windows watchdog | tr -d '\n')"
echo "ok 8 headless: no watchdog, no window on any screen"
stop

# F. A foreground launch gets its window from AppKit (opt-in: takes the front).
if [ "${COPPER_FIXTURE_FOREGROUND:-0}" = 1 ]; then
  fresh_world
  rm -f "$folder/instance.lock"
  open -n --env "SEARCH_PROBE=$world" --env "SEARCH_MCP_PORT=$port" --env COPPER_LAUNCH_WATCHDOG=off "$app"
  for _ in {1..80}; do pid=$(cat "$folder/instance.lock" 2>/dev/null || true); [ -n "$pid" ] && break; sleep 0.25; done
  until_windows 1 || fail "F: a foreground launch, watchdog off, has $(wins) windows — the Room still blocks the first window"
  [ -z "$(recovery)" ] || fail "F: the window came from a recovery path: $(recovery)"
  echo "ok F a foreground launch with a page restored in the Room got its window from AppKit itself"
  stop
fi

echo "PASS launch-window-e2e"
