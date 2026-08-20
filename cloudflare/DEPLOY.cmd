@echo off
setlocal
cd /d "%~dp0"
where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 is required. Install it, then run DEPLOY.cmd again.
  pause
  exit /b 1
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\cloudflare-deploy.ps1"
set "exitCode=%ERRORLEVEL%"
echo.
if not "%exitCode%"=="0" echo Cloudflare deployment stopped with exit code %exitCode%.
pause
exit /b %exitCode%
