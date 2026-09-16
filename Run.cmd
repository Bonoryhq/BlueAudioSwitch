@echo off
title BlueAudioSwitch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ApplyFallbackPatch.ps1" -Target "%~dp0BlueAudioSwitch.ps1"
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1"
