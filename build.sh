#!/bin/bash
# Builds build/Solo.app (ad-hoc signed).
# ./build.sh --install  also replaces /Applications/Solo.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Solo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -dynamiclib -O2 -framework Foundation \
  helper/SoloHelper.m -o "$APP/Contents/Resources/SoloHelper.dylib"
cp helper/launch.pl "$APP/Contents/Resources/"

swiftc -O app/main.swift -o "$APP/Contents/MacOS/Solo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.solo</string>
  <key>CFBundleName</key><string>Solo</string>
  <key>CFBundleExecutable</key><string>Solo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Solo pauses and resumes Spotify and Music so only one thing plays at a time.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/SoloHelper.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "local.solo"' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Solo.app
  ditto "$APP" /Applications/Solo.app
  open /Applications/Solo.app
  echo "Installed /Applications/Solo.app"
fi
