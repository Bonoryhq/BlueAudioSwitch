<p align="center">
  <img src="assets/hero.png" alt="BlueAudioSwitch automatically switching Windows audio outputs" width="100%">
</p>

<h1 align="center">BlueAudioSwitch</h1>

<p align="center">
  Automatic Windows audio output switching based on what is actually connected.<br>
  Bluetooth devices, built-in speakers, and special support for the Dark Project HS5 2.4 GHz receiver.
</p>

<p align="center">
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows">
  <img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-34D058">
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-2EA44F">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## What it is

BlueAudioSwitch is a small Windows utility that keeps the default audio output in sync with the devices you are actually using.

Instead of manually opening the Windows sound menu every time a speaker, headset, or Bluetooth device connects or disconnects, BlueAudioSwitch watches device state and switches the default output automatically.

The main rule is simple: **the most recently connected available audio device wins**. If that device disappears, BlueAudioSwitch falls back to another active device and ultimately to the laptop's built-in speakers when no external output remains.

## What it does

- Watches Bluetooth audio devices and physical Bluetooth connection events.
- Gives priority to the device that connected most recently.
- Automatically requests reconnection for paired Bluetooth audio devices that are currently disconnected.
- Waits for the real playback endpoint to become active before switching.
- Prefers Stereo/A2DP playback over Hands-Free call-quality profiles.
- Switches all three Windows audio roles: Console, Multimedia, and Communications.
- Returns to another active output when the current device disconnects.
- Falls back to the laptop's built-in speakers when no external audio device remains active.
- Runs in the background and starts with the current Windows user.
- Uses built-in Windows APIs only. There is no telemetry or network access.

## Dark Project HS5 / DP-HS-1015 support

Dark Project HS5 is a special case because its 2.4 GHz USB receiver stays visible to Windows even when the headset itself is powered off. Windows therefore cannot tell from the audio endpoint alone whether the headset is actually reachable.

BlueAudioSwitch adds dedicated support for this receiver by listening to its real wireless link-state HID report:

- HS5 turns on and establishes the 2.4 GHz link -> audio switches to `Speakers (DP-HS-1015)`.
- HS5 turns off -> BlueAudioSwitch leaves the permanently present dongle and returns to the most appropriate active output.
- If the previous Bluetooth device is still connected, it can become active again.
- If no external device remains, audio falls back to the laptop's built-in speakers.

This HS5 integration is an extra device-specific capability on top of the general automatic audio-switching behavior.

<p align="center">
  <img src="assets/how-it-works.svg" alt="How the HS5 connection report controls Windows audio" width="920">
</p>

## Supported HS5 receiver

The dedicated HS5 integration currently targets the receiver shipped with Dark Project HS5 / DP-HS-1015:

```text
USB VID: 10D6
USB PID: B011
HID usage page: FF90
Input report ID: 55
```

Other Bluetooth audio devices use the general BlueAudioSwitch logic. Other proprietary 2.4 GHz receivers are not assumed compatible with the HS5 HID integration unless their protocol is verified separately.

## Future / roadmap

The long-term goal is to make proprietary wireless audio dongles a first-class extension point instead of handling each model directly in the core logic.

Planned direction:

- **Dongle profiles** — device-specific profiles identified by USB `VID/PID` plus a small parser for the relevant HID/vendor report.
- **Generic dongle engine** — the main audio-switching logic stays device-agnostic, while profiles only answer one question: is the wireless audio link really connected?
- **Learning mode** — capture several headset ON/OFF cycles and compare HID reports to help discover which byte or bit represents link state on an unknown dongle.
- **Community profiles** — allow new dongle definitions to be added without changing the core application.
- **HS5 as the reference profile** — `VID_10D6&PID_B011` remains the first verified implementation and a template for adding other receivers.

The goal is not to assume that every USB audio dongle uses the same protocol. Instead, BlueAudioSwitch should provide one universal switching engine with small adapters for proprietary receiver protocols.

## Install

1. Download the ZIP from [Releases](../../releases/latest).
2. Extract it to a normal folder.
3. Run `Test.cmd` if you want to watch the behavior before installation.
4. Run `Install.cmd`.

The script is copied to:

```text
%LOCALAPPDATA%\BlueAudioSwitch
```

It then starts automatically with the current Windows user. Administrator rights are not required.

## Uninstall

Run `Uninstall.cmd`. It removes the startup entry and the installed copy.

## HS5 receiver signal

The DP-HS-1015 receiver exposes a vendor HID collection and sends a 64-byte input report whenever the 2.4 GHz wireless link changes:

```text
55 6B 00 ... 44 50 2D 48 53 2D 31 30 31 35  # connected
55 6B 01 ... 44 50 2D 48 53 2D 31 30 31 35  # disconnected
```

Byte 2 is the state: `00` means connected and `01` means disconnected. Bytes 9-18 contain `DP-HS-1015` in ASCII. BlueAudioSwitch only reads this collection; it does not send vendor commands or modify firmware.

The capture and validation notes are in [docs/protocol.md](docs/protocol.md).

## Troubleshooting

### A Bluetooth device does not become the default output

Check that the device is paired and connected in Windows. Bluetooth drivers do not all expose the same reconnect behavior, so some OEM drivers may ignore the reconnect request even though manual connection still works.

The log is stored here:

```text
%LOCALAPPDATA%\BlueAudioSwitch\BlueAudioSwitch.log
```

### HS5 does not trigger a switch

Check that Device Manager shows `DP-HS-1015` and that its USB ID is `VID_10D6&PID_B011`.

A normal HS5 power cycle should produce log lines containing:

```text
DP-HS-1015 connected (HID 55-6B-00).
DP-HS-1015 disconnected (HID 55-6B-01).
```

## Privacy and safety

BlueAudioSwitch reads local audio endpoint state, Bluetooth connection state, and the HS5 HID input report when that receiver is present. It does not record audio, contact the internet, collect analytics, flash the receiver, or send unknown vendor commands.

See [SECURITY.md](SECURITY.md) for reporting security issues.

## Credits

BlueAudioSwitch is distributed under the MIT License. The original copyright notice by Wihred is preserved in [LICENSE](LICENSE).
