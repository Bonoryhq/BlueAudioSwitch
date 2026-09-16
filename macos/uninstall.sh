#!/bin/bash
set -euo pipefail

LABEL="io.bonory.blueaudioswitch"
DOMAIN="gui/$(id -u)"
APP_DIR="$HOME/Library/Application Support/BlueAudioSwitch"
PLIST_PATH="$HOME/Library/LaunchAgents/io.bonory.blueaudioswitch.plist"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_PATH"
rm -f "$APP_DIR/blueaudioswitch-mac"
rmdir "$APP_DIR" >/dev/null 2>&1 || true

echo "BlueAudioSwitch macOS removed from LaunchAgents and Application Support."
echo "Logs were kept in: $HOME/Library/Logs/BlueAudioSwitch"
