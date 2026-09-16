@echo off
title BlueAudioSwitch - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ApplyFallbackPatch.ps1" -Target "%~dp0BlueAudioSwitch.ps1"
if errorlevel 1 (
  echo.
  echo Failed to apply fallback patch.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Install
echo.
echo Installation complete.
pause >nul
