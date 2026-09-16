<p align="center">
  <img src="assets/hero.png" alt="USB receiver switching audio to a wireless headset" width="100%">
</p>

<h1 align="center">BlueAudioSwitch HS5</h1>

<p align="center">
  Windows audio switching that follows the actual radio link of the Dark Project HS5,<br>
  not the permanently connected USB receiver.
</p>

<p align="center">
  <img alt="Windows 10 and 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows">
  <img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-34D058">
  <img alt="No telemetry" src="https://img.shields.io/badge/telemetry-none-2EA44F">
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

## The problem

The DP-HS-1015 USB receiver never disappears from Windows. Its playback endpoint stays active even when the headset is powered off, so ordinary device-presence checks cannot tell whether audio will actually reach the headset.

BlueAudioSwitch HS5 listens to the receiver's own link-state report instead. Turn the headset on and Windows selects `Speakers (DP-HS-1015)`. Turn it off and the previous output comes back.

The HS5 support is an addition to the original BlueAudioSwitch behavior, not a replacement for it. The app also watches classic Bluetooth audio devices, periodically asks disconnected paired devices to reconnect, and moves Windows audio to the device that connected most recently. When several Bluetooth profiles exist, it prefers the normal Stereo/A2DP playback endpoint over the Hands-Free call-quality endpoint.

No polling by sound playback, no firmware changes, and no permanent USB capture driver.

<p align="center">
  <img src="assets/how-it-works.svg" alt="How the HS5 connection report controls Windows audio" width="920">
</p>

## What it does

- Detects the real HS5 wireless link while the receiver remains plugged in.
- Switches all three Windows audio roles to the DP-HS-1015 output.
- Restores the output that was active before the headset connected.
- Automatically requests reconnection for paired Bluetooth audio devices that are currently disconnected.
- Detects physical Bluetooth connection edges and gives priority to the device that connected last.
- Switches all three Windows audio roles when the winning Bluetooth device's active playback endpoint appears.
- Prefers Stereo/A2DP over Hands-Free audio for Bluetooth devices.
- Restores the previous non-Bluetooth output after the last Bluetooth audio device disconnects.
- Runs in the background and starts with the current Windows user.
- Uses only built-in Windows APIs. There is no network access or telemetry.

## Supported receiver

This build targets the receiver shipped with Dark Project HS5 / DP-HS-1015:

```text
USB VID: 10D6
USB PID: B011
HID usage page: FF90
Input report ID: 55
```

Other headsets may use the same enclosure or USB audio chip but a different HID protocol. They are not assumed compatible.

## Install

1. Download the ZIP from [Releases](../../releases/latest).
2. Extract it to a normal folder.
3. Run `Test.cmd` if you want to watch it before installation.
4. Run `Install.cmd`.

The script is copied to:

```text
%LOCALAPPDATA%\BlueAudioSwitch
```

It then starts through the current user's Windows startup entry. Administrator rights are not required.

## Uninstall

Run `Uninstall.cmd`. It removes the startup entry and the installed copy.

## The receiver signal

The receiver exposes a vendor HID collection and sends one 64-byte input report whenever the 2.4 GHz link changes:

```text
55 6B 00 ... 44 50 2D 48 53 2D 31 30 31 35  # connected
55 6B 01 ... 44 50 2D 48 53 2D 31 30 31 35  # disconnected
```

Byte 2 is the state: `00` means connected and `01` means disconnected. Bytes 9–18 contain `DP-HS-1015` in ASCII. The app only reads this collection; it does not send vendor commands.

The capture and validation notes are in [docs/protocol.md](docs/protocol.md).

## Troubleshooting

### The headset does not trigger a switch

Check that Device Manager shows `DP-HS-1015` and that its USB ID is `VID_10D6&PID_B011`. Then inspect:

```text
%LOCALAPPDATA%\BlueAudioSwitch\BlueAudioSwitch.log
```

A normal power cycle produces these lines:

```text
DP-HS-1015 connected (HID 55-6B-00). USB headset selected.
DP-HS-1015 disconnected (HID 55-6B-01).
DP-HS-1015 disconnected. Restored previous output.
```

### Bluetooth reconnect behaves differently on my PC

Bluetooth drivers do not all expose the same reconnect behavior. The app uses the Windows Bluetooth audio kernel-streaming interface, but an OEM driver may ignore that request. Manual Bluetooth connection still works; HS5 detection is independent of it.

## Privacy and safety

BlueAudioSwitch reads local endpoint state and one HID input report. It does not record audio, contact the internet, collect analytics, or flash the receiver. See [SECURITY.md](SECURITY.md) for reporting security issues.

## Credits

BlueAudioSwitch is distributed under the MIT License. The original copyright notice by Wihred is preserved in [LICENSE](LICENSE).
