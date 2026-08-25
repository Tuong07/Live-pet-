#!/bin/bash
# Builds the disposable window-behaviour demo into a .app bundle.
# A bundle is required: LSUIElement and NSStatusItem need an Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

APP="LivePetDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macosx14.0 \
       -o "$APP/Contents/MacOS/LivePetDemo" main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LivePetDemo</string>
  <key>CFBundleIdentifier</key><string>dev.livepet.demo</string>
  <key>CFBundleName</key><string>Live-pet Demo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "built $APP"
