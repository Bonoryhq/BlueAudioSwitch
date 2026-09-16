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
BUNDLED_BIN="$SCRIPT_DIR/blueaudioswitch-mac"

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"

if [[ -f "$BUNDLED_BIN" ]]; then
  SOURCE_BIN="$BUNDLED_BIN"
  echo "Using bundled BlueAudioSwitch universal binary."
else
  if ! command -v swift >/dev/null 2>&1; then
    echo "No bundled binary was found and Swift is not installed."
    echo "Download the macOS release ZIP, or install Apple Command Line Tools with: xcode-select --install"
    exit 1
  fi

  echo "Building BlueAudioSwitch for macOS from source..."
  swift build --package-path "$SCRIPT_DIR" -c release
  SOURCE_BIN="$SCRIPT_DIR/.build/release/blueaudioswitch-mac"
fi

if [[ ! -f "$SOURCE_BIN" ]]; then
  echo "BlueAudioSwitch executable was not found: $SOURCE_BIN"
  exit 1
fi

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
cp "$SOURCE_BIN" "$BIN_PATH"
chmod +x "$BIN_PATH"
# A GitHub-downloaded ZIP may carry the quarantine xattr. The binary is open-source
# and built by this repository's release workflow, so remove that attribute on the
# installed copy to allow the background LaunchAgent to start normally.
xattr -d com.apple.quarantine "$BIN_PATH" >/dev/null 2>&1 || true

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
echo "List devices with: \"$BIN_PATH\" --list"
