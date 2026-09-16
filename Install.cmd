@echo off
title BlueAudioSwitch - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Install
echo.
echo Installation complete.
pause >nul
