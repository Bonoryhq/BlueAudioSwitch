# Changelog

## 0.3.0 — 2026-09-16

- Added the first native macOS implementation in Swift.
- Added Core Audio output discovery and default-output switching on macOS.
- Added last-available external-device priority and built-in Mac speaker fallback.
- Added support for Bluetooth, Bluetooth LE, USB, AirPlay, HDMI, DisplayPort, Thunderbolt and FireWire Core Audio outputs.
- Added the Dark Project HS5 / DP-HS-1015 HID link-state profile on macOS.
- Added a LaunchAgent installer/uninstaller for background startup on macOS.
- Added universal macOS builds for both Apple Silicon (`arm64`) and Intel (`x86_64`).
- Added macOS CI on GitHub Actions with native build and smoke-test validation.
- Reframed BlueAudioSwitch as a cross-platform automatic audio switching project, with HS5 as the first proprietary dongle profile rather than the whole product.

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
