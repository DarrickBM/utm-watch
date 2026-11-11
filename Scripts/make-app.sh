#!/bin/bash
# Builds UTMWatch.app from the SwiftPM release build and signs it.
# Usage: Scripts/make-app.sh            (signs with the first valid "Apple Development" identity, else ad hoc)
#        SIGN_IDENTITY="..." Scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# OUT_DIR lets a release build go somewhere other than the copy you run day to day.
APP="${OUT_DIR:-build}/UTMWatch.app"
BUNDLE_ID="com.darrick.utmwatch"
VERSION="${VERSION:-0.3.0}"

swift build -c release --product UTMWatchApp
swift build -c release --product utmwatch-mcp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/UTMWatchApp "$APP/Contents/MacOS/UTMWatch"
cp .build/release/utmwatch-mcp "$APP/Contents/MacOS/utmwatch-mcp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UTMWatch</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>UTM Watch</string>
  <key>CFBundleDisplayName</key><string>UTM Watch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>UTM Watch pings your router and your virtual machines to measure how responsive they are.</string>
  <key>NSAppleEventsUsageDescription</key><string>UTM Watch asks UTM for the names and states of your virtual machines.</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "No valid Apple Development identity found: signing ad hoc (macOS will re-ask for permissions after each rebuild)."
  IDENTITY="-"
fi
# Nested executables are signed first, then the bundle.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.mcp" "$APP/Contents/MacOS/utmwatch-mcp"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP" && echo "Built and signed $APP"
