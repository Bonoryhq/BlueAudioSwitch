@echo off
title BlueAudioSwitch - Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SpeakerFallback.ps1" -Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Uninstall
echo.
echo Uninstall command completed.
pause >nul
