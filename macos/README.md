# BlueAudioSwitch for macOS

Native macOS implementation of BlueAudioSwitch.

It uses **Core Audio** to watch and switch output devices and **IOKit / HID** for device-specific dongle support. There is no Electron app and no tray/menu-bar process in this first version.

## Current behavior

- Watches macOS output devices exposed by Core Audio.
- Treats Bluetooth, Bluetooth LE, USB, AirPlay, HDMI, DisplayPort, Thunderbolt and FireWire outputs as external devices.
- Gives priority to the most recently available external output.
- Falls back to another available external device when the current output disappears.
- Falls back to the Mac's built-in output when no external output remains.
- Preserves a manual output change until another device becomes available.
- Sets both the normal default output and the system-sounds output.
- Adds dedicated Dark Project HS5 / DP-HS-1015 link-state detection through HID.

## HS5 support

The HS5 dongle can stay visible to Core Audio even when the headset itself is powered off. For that device, BlueAudioSwitch reads the same link-state report used by the Windows implementation:

```text
55 6B 00  -> headset connected
55 6B 01  -> headset disconnected
```

Supported profile:

```text
VID: 10D6
PID: B011
```

When the HID state is known, the DP-HS-1015 Core Audio endpoint is considered available only while the actual radio link is connected.

## Requirements

- macOS 13 or newer.
- The release ZIP contains a **universal binary** for Apple Silicon (`arm64`) and Intel (`x86_64`).
- Swift / Xcode are only required when building from source.

## Install from release

1. Download `BlueAudioSwitch-macOS-v0.3.0.zip` from GitHub Releases.
2. Extract it.
3. In Terminal, open the extracted folder and run:

```bash
chmod +x install.sh uninstall.sh
./install.sh
```

The release installer uses the bundled universal binary; it does not compile anything locally.

Installed binary:

```text
~/Library/Application Support/BlueAudioSwitch/blueaudioswitch-mac
```

Autostart:

```text
~/Library/LaunchAgents/io.bonory.blueaudioswitch.plist
```

Logs:

```text
~/Library/Logs/BlueAudioSwitch/BlueAudioSwitch.log
~/Library/Logs/BlueAudioSwitch/BlueAudioSwitch.error.log
```

List detected output devices:

```bash
"$HOME/Library/Application Support/BlueAudioSwitch/blueaudioswitch-mac" --list
```

## Build / test from source

Requires Apple Command Line Tools / Swift 5.9 or newer.

```bash
cd macos
swift run blueaudioswitch-mac --list
```

Run in the foreground:

```bash
cd macos
swift run blueaudioswitch-mac
```

Source installation uses the same script. If no bundled binary is present, `install.sh` builds a release binary locally:

```bash
cd macos
chmod +x install.sh uninstall.sh
./install.sh
```

## Uninstall

```bash
cd macos
./uninstall.sh
```

## Notes and current limitations

### Generic Bluetooth / AirPlay / USB detection

The generic macOS implementation follows Core Audio device availability. For normal Bluetooth devices this maps naturally to the audio endpoint becoming available/unavailable.

### Proprietary 2.4 GHz dongles

A USB dongle may remain permanently available even when the wireless headset behind it is off. Those devices need a device profile that exposes their real radio-link state. HS5 is the first implemented profile.

Future work matches the main project roadmap:

- VID/PID based dongle profiles.
- Pluggable HID/vendor parsers.
- Learning mode for unknown dongles.
- Community-maintained profiles.

### Startup state of HS5

The current implementation intentionally does not send vendor commands to query the receiver. Until the first HS5 link-state report is observed after the process starts, the program does not claim to know the headset's radio state. Once a `55 6B 00/01` report is received, HID state becomes authoritative.

## Architecture

```text
Core Audio devices
       |
       v
availability + transport type
       |
       +--------------------------+
       |                          |
       v                          v
normal device logic        dongle profile logic
                                  |
                                  v
                              IOHID report
       |                          |
       +------------+-------------+
                    v
        last-connected selection
                    |
                    v
        Core Audio default output
                    |
                    v
          built-in Mac fallback
```
