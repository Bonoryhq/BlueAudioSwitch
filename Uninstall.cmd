@echo off
title BlueAudioSwitch - Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'BlueAudioSwitchSpeakerFallback' -ErrorAction SilentlyContinue; Get-CimInstance Win32_Process -ErrorAction SilentlyContinue ^| Where-Object { $_.CommandLine -match '[\\/]SpeakerFallback\.ps1' } ^| ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate -ErrorAction SilentlyContinue ^| Out-Null }"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BlueAudioSwitch.ps1" -Uninstall
echo.
echo Uninstall command completed.
pause >nul
