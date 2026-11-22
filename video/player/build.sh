#!/bin/bash
# Playback.app を作る(Swift、外部ライブラリなし)。
set -e
cd "$(dirname "$0")"
APP=build/Playback.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -o "$APP/Contents/MacOS/Playback" Sources/*.swift \
  -framework Cocoa -framework AVFoundation -framework CoreAudio
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Playback</string>
  <key>CFBundleIdentifier</key><string>local.playback</string>
  <key>CFBundleExecutable</key><string>Playback</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "できました: $(pwd)/$APP"
