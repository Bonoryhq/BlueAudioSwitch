@echo off
title BlueAudioSwitch - Test
echo BlueAudioSwitch is running in test mode.
echo Turn on your Dark Project HS5 or a Bluetooth audio device already paired with Windows.
echo Press Ctrl+C to stop.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Test
echo.
pause
