#!/bin/sh
#
# Copper installer — a small, fast WebKit browser for macOS.
#
#   curl -fsSL https://github.com/copper-browser/Copper/releases/latest/download/copper-install.sh | sh
#
# Downloads the latest release from GitHub, verifies its SHA-256, backs up
# your tab session, replaces /Applications/Copper.app, clears the quarantine
# flag (builds are signed with Copper's own certificate, not notarized), links the `copper` CLI shim
# onto PATH when the build ships one, and relaunches. Re-running upgrades in
# place. Never uses sudo.
#
# Prefer Homebrew if you have it — it is the same bytes:
#   brew install --cask copper-browser/copper/copper
#
# Flags:
#   --cli-only     only (re)link the CLI shim from the already-installed app
#   --no-launch    do not relaunch Copper afterwards (same as COPPER_NO_LAUNCH=1)
#
# Environment:
#   COPPER_FEED         where releases come from (default
#                       https://github.com/copper-browser/Copper/releases/latest/download)
#   COPPER_INSTALL_DIR  where Copper.app goes (default /Applications)
#   COPPER_BIN_DIR      where the `copper` shim is linked (default: first
#                       writable of /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)
#   COPPER_NO_LAUNCH    set to 1 to skip `open -a Copper`
#
# This file is attached verbatim to every GitHub release by
# .github/workflows/release.yml in copper-browser/Copper — keep it
# dependency-free POSIX sh (no jq, no python: a fresh Mac without the Xcode
# CLT must be able to run it).

set -eu

FEED="${COPPER_FEED:-https://github.com/copper-browser/Copper/releases/latest/download}"
FEED="${FEED%/}"
INSTALL_DIR="${COPPER_INSTALL_DIR:-/Applications}"
APP="$INSTALL_DIR/Copper.app"
# Set by check_platform: copper-macos-arm64.zip or copper-macos-x86_64.zip.
ZIP_NAME=""
SUPPORT_DIR="$HOME/Library/Application Support/Copper"
QUIT_TIMEOUT=15

CLI_ONLY=0
NO_LAUNCH="${COPPER_NO_LAUNCH:-0}"
for arg in "$@"; do
	case "$arg" in
	--cli-only) CLI_ONLY=1 ;;
	--no-launch) NO_LAUNCH=1 ;;
	-h | --help)
		sed -n '2,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'copper-install: unknown flag: %s\n' "$arg" >&2
		exit 2
		;;
	esac
done

die() {
	printf 'copper-install: %s\n' "$1" >&2
	exit 1
}

info() {
	printf '==> %s\n' "$1"
}

note() {
	printf '    %s\n' "$1"
}

app_version() {
	# Fall back to "unknown" rather than failing: the About-box string is
	# informational; a plist without it is still an installable app.
	if [ -f "$1/Contents/Info.plist" ]; then
		/usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown
	else
		echo unknown
	fi
}

check_platform() {
	[ "$(uname -s)" = "Darwin" ] || die "Copper is a macOS app; this is $(uname -s)"
	arch="$(uname -m)"
	# A terminal running under Rosetta says x86_64 on Apple Silicon; the Mac
	# itself still gets the Apple Silicon build.
	if [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
		arch=arm64
	fi
	case "$arch" in
	arm64 | x86_64) ZIP_NAME="copper-macos-$arch.zip" ;;
	*) die "unsupported CPU architecture: $arch" ;;
	esac
}

pick_bin_dir() {
	if [ -n "${COPPER_BIN_DIR:-}" ]; then
		mkdir -p "$COPPER_BIN_DIR" 2>/dev/null || true
		[ -d "$COPPER_BIN_DIR" ] && [ -w "$COPPER_BIN_DIR" ] && { echo "$COPPER_BIN_DIR"; return 0; }
		die "COPPER_BIN_DIR=$COPPER_BIN_DIR is not a writable directory"
	fi
	for candidate in /opt/homebrew/bin /usr/local/bin; do
		if [ -d "$candidate" ] && [ -w "$candidate" ]; then
			echo "$candidate"
			return 0
		fi
	done
	mkdir -p "$HOME/.local/bin"
	echo "$HOME/.local/bin"
}

link_cli() {
	shim="$APP/Contents/Resources/bin/copper"
	if [ ! -x "$shim" ]; then
		note "this build has no CLI shim (Contents/Resources/bin/copper); skipping the PATH link"
		CLI_PATH=""
		return 0
	fi
	bin_dir="$(pick_bin_dir)"
	ln -sfn "$shim" "$bin_dir/copper"
	CLI_PATH="$bin_dir/copper"
	info "linked $CLI_PATH -> $shim"
	case ":${PATH}:" in
	*":$bin_dir:"*) ;;
	*)
		note "$bin_dir is not on your PATH. Add to your shell profile:"
		note "  export PATH=\"$bin_dir:\$PATH\""
		;;
	esac
}

running_copper_path() {
	# The executable path of a running Copper, if any. Matching on the full
	# bundle path (not just the process name) is what keeps a sandboxed install
	# (COPPER_INSTALL_DIR elsewhere) from quitting the real /Applications copy.
	# shellcheck disable=SC2009  # pgrep cannot return the executable path; the path IS the check
	ps -axo comm= 2>/dev/null | grep -F "/Copper.app/Contents/MacOS/Copper" | head -n 1 || true
}

quit_if_running() {
	running="$(running_copper_path)"
	[ -n "$running" ] || return 0
	case "$running" in
	"$APP/Contents/MacOS/Copper") ;;
	*)
		note "a Copper is running from $running (not $APP); leaving it alone"
		return 0
		;;
	esac
	info "Copper is running from $APP — asking it to quit"
	/usr/bin/osascript -e 'tell application "Copper" to quit' >/dev/null 2>&1 || true
	waited=0
	while [ "$waited" -lt "$QUIT_TIMEOUT" ]; do
		[ -n "$(running_copper_path)" ] || return 0
		sleep 1
		waited=$((waited + 1))
	done
	note "Copper did not quit within ${QUIT_TIMEOUT}s; forcing it"
	pkill -x Copper 2>/dev/null || true
	sleep 1
}

backup_session() {
	session="$SUPPORT_DIR/session.json"
	[ -f "$session" ] || return 0
	stamp="$(date +%Y%m%d-%H%M%S)"
	backup="$SUPPORT_DIR/session.backup-$stamp.json"
	cp -p "$session" "$backup"
	info "backed up tab session to $backup"
	note "(replacing the app can drop the open-tab session; restore by copying it back over session.json with Copper quit)"
}

fetch() {
	# -f: fail on HTTP errors; -L: follow GitHub's redirect to the asset host.
	status=0
	curl -fsSL --retry 2 --connect-timeout 10 -o "$2" "$1" || status=$?
	[ "$status" -eq 0 ] && return 0
	case "$status" in
	6 | 7 | 28)
		die "cannot reach $FEED (curl exit $status) — check your internet connection and retry"
		;;
	esac
	die "download failed ($1, curl exit $status)"
}

install_app() {
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/copper-install.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT INT TERM

	info "downloading $FEED/$ZIP_NAME"
	fetch "$FEED/$ZIP_NAME" "$tmp/$ZIP_NAME"

	# The release workflow attaches a shasum-format sidecar next to the zip,
	# computed from the same bytes it uploaded. copper-version.json carries the
	# digest too, but a fresh Mac has no jq/python to parse it — the sidecar
	# keeps this script dependency-free.
	if curl -fsSL --connect-timeout 10 -o "$tmp/$ZIP_NAME.sha256" "$FEED/$ZIP_NAME.sha256" 2>/dev/null; then
		expected="$(cut -d' ' -f1 <"$tmp/$ZIP_NAME.sha256" | tr -d '[:space:]')"
		actual="$(shasum -a 256 "$tmp/$ZIP_NAME" | cut -d' ' -f1)"
		[ -n "$expected" ] || die "empty checksum sidecar in the release"
		[ "$expected" = "$actual" ] || die "checksum mismatch for $ZIP_NAME (expected $expected, got $actual) — a release may be mid-publish; retry in a minute"
		info "sha256 verified ($actual)"
	else
		note "no checksum sidecar published for this build; skipping SHA-256 verification"
	fi

	info "unpacking"
	mkdir -p "$tmp/unpack"
	ditto -x -k "$tmp/$ZIP_NAME" "$tmp/unpack"
	[ -d "$tmp/unpack/Copper.app/Contents" ] || die "archive did not contain Copper.app"

	backup_session
	quit_if_running

	mkdir -p "$INSTALL_DIR" 2>/dev/null || die "cannot create $INSTALL_DIR"
	[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable (set COPPER_INSTALL_DIR to another folder, e.g. ~/Applications)"
	previous=""
	if [ -d "$APP" ]; then
		previous="$(app_version "$APP")"
		rm -rf "$APP"
	fi
	# ditto preserves the bundle's resource forks and permissions, which a
	# plain cp -R does not reliably do for app bundles.
	ditto "$tmp/unpack/Copper.app" "$APP"
	# Not notarized (Copper's own certificate, not a Developer ID): Gatekeeper
	# refuses to launch a quarantined build, so strip the flag exactly like the
	# cask's postflight.
	xattr -cr "$APP" 2>/dev/null || true

	installed="$(app_version "$APP")"
	if [ -n "$previous" ] && [ "$previous" != "$installed" ]; then
		info "replaced Copper $previous with $installed at $APP"
	else
		info "installed Copper $installed at $APP"
	fi
}

main() {
	check_platform
	if [ "$CLI_ONLY" = 1 ]; then
		[ -d "$APP/Contents" ] || die "no Copper.app at $APP to link the CLI from (run without --cli-only first)"
		link_cli
		exit 0
	fi

	install_app
	link_cli

	if [ "$NO_LAUNCH" = 1 ]; then
		note "not launching (COPPER_NO_LAUNCH/--no-launch)"
	else
		info "launching Copper"
		open -a "$APP" || note "open failed; launch Copper from $INSTALL_DIR"
	fi

	printf '\n'
	printf 'Copper %s is installed at %s\n' "$(app_version "$APP")" "$APP"
	if [ -n "${CLI_PATH:-}" ]; then
		printf 'CLI: %s\n' "$CLI_PATH"
	fi
	printf 'Copper updates itself (Settings › Updates). To reinstall, re-run this script,\n'
	printf 'or use Homebrew (same builds): brew install --cask copper-browser/copper/copper\n'
}

main
