@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Duendee Tunnel Tool
rem ASCII-only launcher. UI lives in PowerShell (UTF-8) so Turkish never breaks after cls/menu.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0duendee-tunnel-tool.ps1" %*
set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" (
  echo.
  echo Launcher exited with code %EC%.
  pause
)
exit /b %EC%