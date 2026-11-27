#!/bin/bash
# Print the path of the pinned rcodesign (apple-codesign), fetching it into a
# cache first when it isn't there yet:
#
#   rcodesign="$(release/rcodesign.sh)"
#
# Releases are signed with rcodesign and a .p12 file, never a keychain
# (release/package-app.sh). The tarball is checked against the SHA-256 the
# project publishes and the one pinned here, the binary inside it against its
# own pin, on every run. macOS universal binary; COPPER_RCODESIGN_CACHE names
# another cache folder.
#
# An rcodesign of the pinned version already on PATH (a Roadrunner macOS
# agent's, exo-macsign's) is used as it is: whoever put it there vouches for
# it. COPPER_RCODESIGN_PATH=0 always takes the pinned download.
set -euo pipefail

RCODESIGN_VERSION=0.29.0
RCODESIGN_TARBALL=apple-codesign-$RCODESIGN_VERSION-macos-universal.tar.gz
RCODESIGN_TARBALL_SHA256=d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d
RCODESIGN_SHA256=75ef370d4de9fc99d8b26a168bed9c256da8364d8b9fdb2be762ab42fc6a9978
RCODESIGN_URL=https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/$RCODESIGN_VERSION/$RCODESIGN_TARBALL

fail() { printf 'rcodesign.sh: %s\n' "$*" >&2; exit 1; }

if [ "${COPPER_RCODESIGN_PATH:-1}" != 0 ] && on_path="$(command -v rcodesign 2> /dev/null)" \
  && [ "$("$on_path" --version 2> /dev/null | awk '{ print $2 }')" = "$RCODESIGN_VERSION" ]; then
  printf '%s\n' "$on_path"
  exit 0
fi
cache="${COPPER_RCODESIGN_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/copper-release}"
rcodesign="$cache/apple-codesign-$RCODESIGN_VERSION/rcodesign"
if [ -x "$rcodesign" ] && [ "$(shasum -a 256 "$rcodesign" | cut -d' ' -f1)" = "$RCODESIGN_SHA256" ]; then
  printf '%s\n' "$rcodesign"
  exit 0
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "fetching rcodesign $RCODESIGN_VERSION" >&2
curl -fsSL --retry 3 -o "$work/$RCODESIGN_TARBALL" "$RCODESIGN_URL"
published="$(curl -fsSL --retry 3 "$RCODESIGN_URL.sha256" | tr -d '[:space:]')"
actual="$(shasum -a 256 "$work/$RCODESIGN_TARBALL" | cut -d' ' -f1)"
[ "$published" = "$RCODESIGN_TARBALL_SHA256" ] || fail "rcodesign's published SHA-256 is $published, pinned $RCODESIGN_TARBALL_SHA256"
[ "$actual" = "$RCODESIGN_TARBALL_SHA256" ] || fail "$RCODESIGN_TARBALL is $actual, pinned $RCODESIGN_TARBALL_SHA256"
tar -xzf "$work/$RCODESIGN_TARBALL" -C "$work"
binary="$work/${RCODESIGN_TARBALL%.tar.gz}/rcodesign"
[ "$(shasum -a 256 "$binary" | cut -d' ' -f1)" = "$RCODESIGN_SHA256" ] || fail "the rcodesign in $RCODESIGN_TARBALL is not the pinned binary"
mkdir -p "$(dirname "$rcodesign")"
install -m 755 "$binary" "$rcodesign"
printf '%s\n' "$rcodesign"
