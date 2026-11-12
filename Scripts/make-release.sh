#!/bin/bash
# Builds the downloadable release files into dist/:
#   UTMWatch-<version>-macos-arm64.dmg      the menu bar app as a disk image (drag to Applications)
#   UTMWatch-<version>-macos-arm64.zip      the same app as a zip (used by install.sh)
#   utmwatch-<version>-macos-arm64.tar.gz   the terminal tool
# Both are signed ad hoc: a personal development certificate would embed its owner's email in every
# download, and proper distribution signing needs a paid Developer ID. Users clear the quarantine
# flag once after downloading (see README).
# Usage: Scripts/make-release.sh 0.6.0          a final release, published as tag v0.6.0
#        Scripts/make-release.sh 0.6.0-beta.6   beta 6 of 0.6.0, published as a pre-release with tag v0.6.0-beta.6
# The tag must match: the app's updater reads the beta number from it. File names carry the version only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.6.0}"
BETA=""
case "$VERSION" in
  *-beta.*) BETA="${VERSION##*-beta.}"; VERSION="${VERSION%%-beta.*}"
            case "$BETA" in ''|*[!0-9]*|0) echo "The beta number must be 1 or more, as in 0.6.0-beta.6." >&2; exit 1 ;; esac ;;
  *-*) echo "Unknown version suffix in $VERSION: use <version> or <version>-beta.<n>." >&2; exit 1 ;;
esac
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

VERSION="$VERSION" BETA="$BETA" OUT_DIR="$DIST" SIGN_IDENTITY="-" Scripts/make-app.sh
ditto -c -k --keepParent "$DIST/UTMWatch.app" "$DIST/UTMWatch-$VERSION-macos-arm64.zip"

# Disk image for people who prefer to drag the app into Applications.
DMG_STAGE="$DIST/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$DIST/UTMWatch.app" "$DMG_STAGE/UTMWatch.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "UTM Watch" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST/UTMWatch-$VERSION-macos-arm64.dmg"
rm -rf "$DMG_STAGE" "$DIST/UTMWatch.app"

swift build -c release --product utmwatch
STAGE="$DIST/utmwatch-$VERSION"
mkdir -p "$STAGE"
cp .build/release/utmwatch "$STAGE/utmwatch"
cp LICENSE README.md "$STAGE/"
codesign --force --sign - --identifier com.darrick.utmwatch.cli "$STAGE/utmwatch"
tar -czf "$DIST/utmwatch-$VERSION-macos-arm64.tar.gz" -C "$DIST" "utmwatch-$VERSION"
rm -rf "$STAGE"

( cd "$DIST" && shasum -a 256 *.dmg *.zip *.tar.gz > SHA256SUMS.txt && cat SHA256SUMS.txt )
ls -lh "$DIST"
if [ -n "$BETA" ]; then echo "Publish as a pre-release with tag v$VERSION-beta.$BETA"; else echo "Publish with tag v$VERSION"; fi
