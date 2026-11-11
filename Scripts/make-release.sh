#!/bin/bash
# Builds the downloadable release files into dist/:
#   UTMWatch-<version>-macos-arm64.zip      the menu bar app (includes the utmwatch-mcp helper)
#   utmwatch-<version>-macos-arm64.tar.gz   the terminal tool
# Both are signed ad hoc: a personal development certificate would embed its owner's email in every
# download, and proper distribution signing needs a paid Developer ID. Users clear the quarantine
# flag once after downloading (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

VERSION="$VERSION" OUT_DIR="$DIST" SIGN_IDENTITY="-" Scripts/make-app.sh
ditto -c -k --keepParent "$DIST/UTMWatch.app" "$DIST/UTMWatch-$VERSION-macos-arm64.zip"
rm -rf "$DIST/UTMWatch.app"

swift build -c release --product utmwatch
STAGE="$DIST/utmwatch-$VERSION"
mkdir -p "$STAGE"
cp .build/release/utmwatch "$STAGE/utmwatch"
cp LICENSE README.md "$STAGE/"
codesign --force --sign - --identifier com.darrick.utmwatch.cli "$STAGE/utmwatch"
tar -czf "$DIST/utmwatch-$VERSION-macos-arm64.tar.gz" -C "$DIST" "utmwatch-$VERSION"
rm -rf "$STAGE"

( cd "$DIST" && shasum -a 256 *.zip *.tar.gz > SHA256SUMS.txt && cat SHA256SUMS.txt )
ls -lh "$DIST"
