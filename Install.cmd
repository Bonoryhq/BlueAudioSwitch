@echo off
title BlueAudioSwitch - Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'BlueAudioSwitchSpeakerFallback' -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object { $_.CommandLine -match '[\\/]SpeakerFallback\.ps1' } ^| ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue ^| Out-Null }"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ApplyFallbackPatch.ps1" -Target "%~dp0BlueAudioSwitch.ps1"
if errorlevel 1 (
  echo.
  echo Failed to apply fallback patch.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Install
if errorlevel 1 (
  echo.
  echo BlueAudioSwitch installation failed.
  echo The startup registration was not confirmed.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$entry = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'BlueAudioSwitch' -ErrorAction SilentlyContinue).BlueAudioSwitch; if ([string]::IsNullOrWhiteSpace($entry)) { exit 1 }"
if errorlevel 1 (
  echo.
  echo Installation ran, but BlueAudioSwitch is missing from Windows startup.
  echo Run Install.cmd again and check for errors.
  pause
  exit /b 1
)
echo.
echo Installation complete.
echo Windows startup registration verified.
pause >nul
