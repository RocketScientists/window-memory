#!/bin/bash
# Stops WindowMemory and removes the app and LaunchAgent. Saved layouts are kept
# in ~/Library/Application Support/WindowMemory unless you pass --purge.
set -euo pipefail

LABEL=local.window-memory
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/WindowMemory.app"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/Library/Application Support/WindowMemory"
  tccutil reset Accessibility "$LABEL" 2>/dev/null || true
fi
echo "Uninstalled."
