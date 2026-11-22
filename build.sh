#!/bin/bash
# Builds build/WindowMemory.app using only Apple's Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WindowMemory.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/WindowMemory" WindowMemory.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.window-memory</string>
  <key>CFBundleName</key><string>Window Memory</string>
  <key>CFBundleExecutable</key><string>WindowMemory</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS can remember the Accessibility permission.
codesign --force --sign - --identifier local.window-memory "$APP"
echo "Built $APP"
