# Changelog

## 0.2.1 — 2026-09-16

- Fixed HS5 disconnect fallback when the previously used Bluetooth device has already disconnected.
- Preserved the existing "last connected device wins" behavior for active Bluetooth devices.
- Added final fallback to the laptop's built-in speakers when no external audio device remains active.
- Prevented the permanently present `DP-HS-1015` USB receiver from being kept as the fallback after the headset disconnects.
- Removed the temporary standalone fallback watchdog; fallback selection is now integrated into the main BlueAudioSwitch flow.

## 0.2.0 — 2026-09-16

- Added passive Dark Project HS5 / DP-HS-1015 link detection through HID report `55 6B`.
- Added automatic switching to the HS5 USB render endpoint on connect.
- Added restoration of the previous output on disconnect.
- Kept HS5 events responsive while Bluetooth reconnect checks are running.
- Documented the complete Bluetooth behavior: automatic reconnect requests, last-connected-device priority, three-role audio switching, and Stereo/A2DP preference.
- Documented the observed receiver protocol and its safety boundary.
