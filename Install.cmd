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
echo.
echo Installation complete.
pause >nul
