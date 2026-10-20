@echo off
rem AI Cage - double-click to start. "AiCage.cmd console" opens the PowerShell commands instead.
net session >nul 2>&1
if errorlevel 1 (
  if "%~1"=="" (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  ) else (
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
  )
  exit /b
)
if /i "%~1"=="console" (
  title AI Cage
  powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0AiCage.ps1" -Console
) else (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0AiCage.ps1"
)