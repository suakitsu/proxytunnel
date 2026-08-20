@echo off
setlocal
cd /d "%~dp0"
title Stop ProxyTunnel
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required to stop this ProxyTunnel session safely.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop.ps1"
set "exitCode=%ERRORLEVEL%"
if not "%exitCode%"=="0" pause
exit /b %exitCode%
