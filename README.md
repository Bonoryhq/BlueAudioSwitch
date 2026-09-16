<p align="center">
  <img src="assets/hero.png" alt="BlueAudioSwitch automatically switching audio outputs" width="100%">
</p>

<h1 align="center">BlueAudioSwitch</h1>

<p align="center">
  Automatic audio-output switching based on what is actually connected.<br>
  Native implementations for Windows and macOS, plus device profiles for proprietary wireless dongles.
</p>

<p align="center">
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows">
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-34D058">
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-2EA44F">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## What it is

BlueAudioSwitch keeps the default audio output aligned with the device you are actually using.

The main rule is simple: **the most recently connected available audio device wins**. When it disappears, BlueAudioSwitch selects another available external output and finally falls back to the computer's built-in speakers.

This is not a tray UI for manual switching. The goal is to remove the manual step entirely.

## Platforms

### Windows

The Windows implementation lives in the repository root and uses PowerShell plus native Windows audio, Bluetooth and HID APIs.

It currently provides the most complete feature set, including Bluetooth reconnect requests, Stereo/A2DP preference and the verified Dark Project HS5 profile.

Install with `Install.cmd` or inspect behavior first with `Test.cmd`.

### macOS

A native Swift implementation is available in [`macos/`](macos/README.md).

It uses:

- **Core Audio** for output discovery and default-output switching.
- **IOKit / HID** for proprietary dongle profiles.
- **LaunchAgent** for background startup.

Current macOS behavior includes Bluetooth/USB/AirPlay/HDMI-style external-output detection, last-available-device priority, built-in speaker fallback and the HS5 HID profile.

## Core behavior

- Detect available audio outputs.
- Track which external device became available most recently.
- Automatically switch to the latest available external output.
- Fall back to another active external output when the current one disappears.
- Fall back to built-in speakers when no external output remains.
- Respect manual output changes until another device connection event occurs.
- Run without telemetry or cloud services.

Platform-specific integrations add deeper device detection where the operating system's normal audio endpoint state is not enough.

## Proprietary wireless dongles

Some 2.4 GHz USB audio receivers remain visible as a valid audio device even when the wireless headset behind them is powered off. In that situation the operating system sees the dongle, not the real radio link.

BlueAudioSwitch solves that with small device profiles that answer one question:

> Is the actual wireless audio link connected right now?

The switching engine remains generic; only the dongle parser is device-specific.

## Dark Project HS5 / DP-HS-1015

HS5 is the first verified dongle profile.

```text
USB VID: 10D6
USB PID: B011
HID usage page: FF90
Input report ID: 55
```

Observed link reports:

```text
55 6B 00 ... DP-HS-1015  # connected
55 6B 01 ... DP-HS-1015  # disconnected
```

When the radio link connects, BlueAudioSwitch can select the HS5 output. When it disconnects, the permanently present dongle stops being treated as a usable destination and normal fallback logic takes over.

Protocol notes are in [docs/protocol.md](docs/protocol.md).

## Future / roadmap

The long-term goal is a universal switching engine with lightweight adapters for proprietary wireless receivers.

Planned direction:

- **Dongle profiles** identified by USB `VID/PID` plus a small HID/vendor parser.
- **Generic dongle engine** shared by all platforms.
- **Learning mode** to compare several ON/OFF cycles and help identify the link-state byte or bit on an unknown receiver.
- **Community profiles** that can add new receivers without modifying the core switching engine.
- **HS5 as the reference profile** for the first verified implementation.

The project does not assume that every USB audio dongle uses the same protocol.

## Windows install

1. Download the ZIP from [Releases](../../releases/latest).
2. Extract it.
3. Optionally run `Test.cmd`.
4. Run `Install.cmd`.

Installed copy:

```text
%LOCALAPPDATA%\BlueAudioSwitch
```

Uninstall with `Uninstall.cmd`.

## macOS build / install

See [`macos/README.md`](macos/README.md).

Quick source install:

```bash
cd macos
chmod +x install.sh uninstall.sh
./install.sh
```

The macOS implementation is native Swift; it does not use Electron or a menu-bar application.

## Privacy and safety

BlueAudioSwitch reads local audio-device state and, for supported proprietary dongles, local HID link-state reports. It does not record audio, collect analytics or contact a cloud service.

The HS5 integration only reads the observed HID state and does not send unknown vendor commands or modify firmware.

See [SECURITY.md](SECURITY.md) for security reports.

## License

MIT. The original copyright notice is preserved in [LICENSE](LICENSE).
