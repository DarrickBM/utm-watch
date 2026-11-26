#!/bin/bash
# Builds the downloadable release files into dist/:
#   UTMWatch-<version>-macos-arm64.dmg      the menu bar app as a disk image (drag to Applications)
#   UTMWatch-<version>-macos-arm64.zip      the same app as a zip (used by install.sh)
# The app is signed with "UTM Watch Release", a self-signed certificate made once by Scripts/make-signing-identity.sh
# and kept outside the repository. A personal development certificate would embed its owner's email in every
# download, and distribution signing needs a paid Developer ID. Ad-hoc signing cost users their privacy permissions
# on every update, because macOS tied them to each build's hash; this certificate's signature names the certificate,
# so updates keep them. Users still clear the quarantine flag once after downloading (see README).
# Usage: Scripts/make-release.sh 0.6.0          a final release, published as tag v0.6.0
#        Scripts/make-release.sh 0.6.0-beta.6   beta 6 of 0.6.0, published as a pre-release with tag v0.6.0-beta.6
# The tag must match: the app's updater reads the beta number from it. File names carry the version only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.9.6}"
BETA=""
case "$VERSION" in
  *-beta.*) BETA="${VERSION##*-beta.}"; VERSION="${VERSION%%-beta.*}"
            case "$BETA" in ''|*[!0-9]*|0) echo "The beta number must be 1 or more, as in 0.6.0-beta.6." >&2; exit 1 ;; esac ;;
  *-*) echo "Unknown version suffix in $VERSION: use <version> or <version>-beta.<n>." >&2; exit 1 ;;
esac
SIGN_IDENTITY="UTM Watch Release"
# The certificate every release since 0.9.7 was signed with. Signing with another one would cost every user their
# permissions again, so a mismatch stops the build instead of shipping.
SIGN_CERT_SHA1="d1e5e86c1f16b70e22da4337b564dc90a01246e9"
if ! security find-certificate -c "$SIGN_IDENTITY" -Z >/dev/null 2>&1; then
  echo "The signing certificate \"$SIGN_IDENTITY\" is not in the keychain. Run Scripts/make-signing-identity.sh" >&2
  echo "(it imports the saved copy from ~/.utmwatch-signing; a new certificate would cost users their permissions)." >&2
  exit 1
fi
DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

VERSION="$VERSION" BETA="$BETA" OUT_DIR="$DIST" SIGN_IDENTITY="$SIGN_IDENTITY" Scripts/make-app.sh
REQUIREMENT="$(codesign -d -r - "$DIST/UTMWatch.app" 2>&1)"
case "$REQUIREMENT" in
  *"identifier \"com.darrick.utmwatch\" and certificate leaf = H\"$SIGN_CERT_SHA1\""*) ;;
  *) echo "The app's signing requirement is not the expected one:" >&2; echo "$REQUIREMENT" >&2; exit 1 ;;
esac
ditto -c -k --keepParent "$DIST/UTMWatch.app" "$DIST/UTMWatch-$VERSION-macos-arm64.zip"

# Disk image for people who prefer to drag the app into Applications.
DMG_STAGE="$DIST/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$DIST/UTMWatch.app" "$DMG_STAGE/UTMWatch.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "UTM Watch" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST/UTMWatch-$VERSION-macos-arm64.dmg"
rm -rf "$DMG_STAGE" "$DIST/UTMWatch.app"

( cd "$DIST" && shasum -a 256 *.dmg *.zip > SHA256SUMS.txt && cat SHA256SUMS.txt )
ls -lh "$DIST"
if [ -n "$BETA" ]; then echo "Publish as a pre-release with tag v$VERSION-beta.$BETA"; else echo "Publish with tag v$VERSION"; fi
