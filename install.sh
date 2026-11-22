#!/bin/bash
# Builds WindowMemory, copies it to ~/Applications, and starts it at login via a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.window-memory
DEST="$HOME/Applications/WindowMemory.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/WindowMemory.log"

./build.sh

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/WindowMemory.app "$DEST"

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/WindowMemory</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Installed and started. Log: $LOG"
echo "If prompted, allow Window Memory in System Settings → Privacy & Security → Accessibility."
