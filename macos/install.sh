#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/BlueAudioSwitch"
BIN_PATH="$APP_DIR/blueaudioswitch-mac"
PLIST_PATH="$HOME/Library/LaunchAgents/io.bonory.blueaudioswitch.plist"
LOG_DIR="$HOME/Library/Logs/BlueAudioSwitch"
LABEL="io.bonory.blueaudioswitch"
DOMAIN="gui/$(id -u)"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required to build the macOS version."
  echo "Install Apple Command Line Tools with: xcode-select --install"
  exit 1
fi

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"

echo "Building BlueAudioSwitch for macOS..."
swift build --package-path "$SCRIPT_DIR" -c release

SOURCE_BIN="$SCRIPT_DIR/.build/release/blueaudioswitch-mac"
if [[ ! -x "$SOURCE_BIN" ]]; then
  echo "Build completed but executable was not found: $SOURCE_BIN"
  exit 1
fi

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
cp "$SOURCE_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/BlueAudioSwitch.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/BlueAudioSwitch.error.log</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_PATH" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null

echo
echo "BlueAudioSwitch macOS installed."
echo "Binary: $BIN_PATH"
echo "Log:    $LOG_DIR/BlueAudioSwitch.log"
echo "Test devices with: \"$BIN_PATH\" --list"
