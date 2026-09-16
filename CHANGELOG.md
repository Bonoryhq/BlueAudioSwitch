# Changelog

## 0.2.0 — 2026-09-16

- Added passive Dark Project HS5 / DP-HS-1015 link detection through HID report `55 6B`.
- Added automatic switching to the HS5 USB render endpoint on connect.
- Added restoration of the previous output on disconnect.
- Kept HS5 events responsive while Bluetooth reconnect checks are running.
- Documented the complete Bluetooth behavior: automatic reconnect requests, last-connected-device priority, three-role audio switching, and Stereo/A2DP preference.
- Documented the observed receiver protocol and its safety boundary.
