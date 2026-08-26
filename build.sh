#!/bin/bash
# Builds LivePet.app.
#
# XcodeGen is not installed on this machine and the app has zero third-party
# dependencies, so swiftc is enough. Revisit when signing needs a real Xcode
# project (phase 6).
set -euo pipefail
cd "$(dirname "$0")"

APP="LivePet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macosx14.0 -o "$APP/Contents/MacOS/LivePet" \
  LivePet/Crypto/*.swift LivePet/Store/*.swift LivePet/Chat/*.swift \
  LivePet/Net/*.swift LivePet/Pet/*.swift LivePet/App/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LivePet</string>
  <key>CFBundleIdentifier</key><string>dev.livepet.app</string>
  <key>CFBundleName</key><string>Live-pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "built $APP"
