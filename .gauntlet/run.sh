#!/bin/bash
# Build a Copper checkout and bring it up in a probe world seeded with the
# real Arc sidebar, ready for `shot.sh`.
#
#   .gauntlet/run.sh WORLD [CHECKOUT]     CHECKOUT defaults to this repo
#
# Kills any Copper already serving WORLD, rebuilds, reimports Arc into the
# world (so a builder's session-format change is exercised every time),
# launches the binary directly (several checkouts can run at once), waits
# for the bench socket, dismisses the welcome, sizes the window, lands on
# the Exowatt space. `stop.sh WORLD` quits it again — always do that when done.
set -euo pipefail
WORLD="$1"
ROOT="$(cd "${2:-$(dirname "$0")/..}" && pwd)"
cd "$ROOT"

"$(dirname "$0")/stop.sh" "$WORLD"
sleep 0.5

./build.sh debug app 2>&1 | grep -E "error:|built:" || true
[ -x build/Copper.app/Contents/MacOS/Copper ] || { echo "build failed" >&2; exit 1; }

defaults write "com.collinrijock.copper.test.$WORLD" bench -bool true
defaults write "com.collinrijock.copper.test.$WORLD" sidebar -bool true
./arc-import --world "$WORLD" | tail -1

SEARCH_PROBE="$WORLD" nohup build/Copper.app/Contents/MacOS/Copper >"/tmp/copper-$WORLD.log" 2>&1 &
echo $! > "/tmp/copper-$WORLD.pid"
for _ in $(seq 1 40); do
    sleep 0.5
    ./bench --world "$WORLD" probe >/dev/null 2>&1 && break
done
./bench --world "$WORLD" ui welcome off >/dev/null
./bench --world "$WORLD" resize 1440 900 >/dev/null 2>&1 || true
./bench --world "$WORLD" spaces select 1 >/dev/null 2>&1 || true
sleep 1
echo "up: world=$WORLD checkout=$ROOT"
