#!/bin/bash
# Builds UTMWatch.app from the SwiftPM release build and signs it.
# Usage: Scripts/make-app.sh            (signs with the first valid "Apple Development" identity, else ad hoc)
#        SIGN_IDENTITY="..." Scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# OUT_DIR lets a release build go somewhere other than the copy you run day to day.
APP="${OUT_DIR:-build}/UTMWatch.app"
BUNDLE_ID="com.darrick.utmwatch"
VERSION="${VERSION:-0.6.0}"
# The build number tells apart builds that share a version, such as successive betas: the number of commits.
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# BETA=6 marks the build as beta 6 of VERSION. The updater reads it to tell betas of one version apart, and a beta
# build follows the beta channel. Unset for a final release.
BETA="${BETA:-}"
BETA_KEY=""
if [ -n "$BETA" ]; then BETA_KEY="<key>UTMWatchBeta</key><integer>${BETA}</integer>"; fi

swift build -c release --product UTMWatchApp
swift build -c release --product utmwatch-mcp
# Fleet helpers, run by the app as child processes. The hub has its own package so its HTTP library stays out of the app;
# the network helper is a Go program (an embedded Tailscale node) and is skipped, with a notice, when Go is not installed.
swift build -c release --package-path Hub --product utmwatch-hub
NET_HELPER=""
if command -v go >/dev/null 2>&1; then
  (cd Net && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" \
    -tags "ts_omit_aws,ts_omit_bird,ts_omit_tap,ts_omit_kube,ts_omit_completion,ts_omit_ssh,ts_omit_wakeonlan,ts_omit_capture,ts_omit_relayserver,ts_omit_taildrop,ts_omit_tpm,ts_omit_webclient,ts_omit_drive,ts_omit_systray,ts_omit_desktop_sessions,ts_omit_syspolicy" \
    -o bin/utmwatch-net-darwin-arm64 .)
  NET_HELPER="Net/bin/utmwatch-net-darwin-arm64"
else
  echo "Go is not installed: building without the network helper. Fleets on one network work; \"Connect Macs on other networks\" will not."
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/UTMWatchApp "$APP/Contents/MacOS/UTMWatch"
cp .build/release/utmwatch-mcp "$APP/Contents/MacOS/utmwatch-mcp"
cp Hub/.build/release/utmwatch-hub "$APP/Contents/MacOS/utmwatch-hub"
if [ -n "$NET_HELPER" ]; then cp "$NET_HELPER" "$APP/Contents/MacOS/utmwatch-net"; fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# App Transport Security: a fleet's hub is at an address the user chooses (a .local name, a LAN or private-network
# address) and speaks plain HTTP, with the private network providing the encryption, so HTTP cannot be limited to a
# list of domains. The update check still insists on https itself (ReleaseInfo.parse).
# NSAllowsArbitraryLoads must be the only key: macOS ignores it when NSAllowsLocalNetworking is also present, and a
# hub on the private network (a 100.x address, reached through the helper's proxy) is then refused with error -1022.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UTMWatch</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>UTM Watch</string>
  <key>CFBundleDisplayName</key><string>UTM Watch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  ${BETA_KEY}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>UTM Watch pings your router and your virtual machines to measure how responsive they are.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
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
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.hub" "$APP/Contents/MacOS/utmwatch-hub"
if [ -n "$NET_HELPER" ]; then codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.net" "$APP/Contents/MacOS/utmwatch-net"; fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP" && echo "Built and signed $APP"
