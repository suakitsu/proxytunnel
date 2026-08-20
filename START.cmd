@echo off
setlocal
cd /d "%~dp0"
title ProxyTunnel
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required. Install it, then run START.cmd again.
  echo https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
  start "" "https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows"
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
if not "%exitCode%"=="0" (
  echo ProxyTunnel failed to start. See the message above.
  pause
)
exit /b %exitCode%
