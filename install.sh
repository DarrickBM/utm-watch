#!/bin/bash
# Installs UTM Watch: the menu bar app into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/DarrickBM/utm-watch/main/install.sh | bash
#
# It downloads the latest release from GitHub, so nothing is built on your Mac.
# Overrides (mostly for testing): INSTALL_DIR, UTMWATCH_NO_OPEN=1, UTMWATCH_RELEASE_JSON=<file>
set -euo pipefail

REPO="DarrickBM/utm-watch"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

say() { printf '%s\n' "$*"; }
fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "UTM Watch only runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "UTM Watch needs an Apple silicon Mac."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${UTMWATCH_RELEASE_JSON:-}" ]; then
  cp "$UTMWATCH_RELEASE_JSON" "$TMP/release.json"
else
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" -o "$TMP/release.json" || fail "could not reach GitHub."
fi
asset() { grep -o "\"browser_download_url\": *\"[^\"]*$1\"" "$TMP/release.json" | head -1 | sed 's/.*"\(http[^"]*\)"/\1/'; }
APP_URL="$(asset 'macos-arm64\.zip')"
[ -n "$APP_URL" ] || fail "no app download found in the latest release."

say "Downloading UTM Watch..."
curl -fsSL "$APP_URL" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP/app"
[ -d "$TMP/app/UTMWatch.app" ] || fail "the download did not contain UTMWatch.app."

# Replace a running copy cleanly.
if [ -z "${UTMWATCH_NO_OPEN:-}" ]; then
  osascript -e 'tell application id "com.darrick.utmwatch" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/UTMWatch.app"
mv "$TMP/app/UTMWatch.app" "$INSTALL_DIR/UTMWatch.app"
# Files fetched by curl carry no download flag, but clear it anyway in case a copy was dragged in earlier.
xattr -dr com.apple.quarantine "$INSTALL_DIR/UTMWatch.app" 2>/dev/null || true
say "Installed $INSTALL_DIR/UTMWatch.app"

say ""
say "To let an AI agent read the recorded history (optional):"
say "  claude mcp add utm-watch -- \"$INSTALL_DIR/UTMWatch.app/Contents/MacOS/utmwatch-mcp\""
say ""
if [ -z "${UTMWATCH_NO_OPEN:-}" ]; then
  open "$INSTALL_DIR/UTMWatch.app"
  say "UTM Watch is starting. Look for it in the menu bar, and allow the three permission prompts."
fi
