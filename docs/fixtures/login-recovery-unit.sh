#!/bin/bash
# Run the same pure checks as Swift Testing, even with Command Line Tools
# that lack its Testing module. No real Copper data or network is touched.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/main.swift" <<'SWIFT'
crashRecoveryStopsAndStaysStopped()
isolatedProcessDeathsStillRecover()
try onlyKnownIncompatibleExtensionsAreBlocked()
print("PASS: crash recovery budget and extension compatibility")
SWIFT
swiftc -D COPPER_STANDALONE_CHECK \
  "$root/Sources/Search/Fork/CrashRecovery.swift" \
  "$root/Sources/Search/Fork/ExtensionCompatibility.swift" \
  "$root/Tests/SearchTests/LoginRecoveryTests.swift" \
  "$tmp/main.swift" -o "$tmp/check"
"$tmp/check"
